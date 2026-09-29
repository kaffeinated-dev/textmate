#import "LSPClient.h"
#import "LSPFileWatcher.h"
#import "LSPServer.h"
#import <bundles/bundles.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <io/environment.h>
#import <ns/ns.h>
#import <oak/algorithm.h>
#import <plist/plist.h>
#import <settings/settings.h>
#import <text/types.h>

static NSTimeInterval const kChangeDelay       = 0.3; // Whole texts are sent, and diagnostics asked for, once typing pauses this long
static NSTimeInterval const kIdleShutDownDelay = 300; // A server without open documents is stopped after this long
static NSTimeInterval const kRestartDelay      = 60;  // A server that exited is not started again sooner

// Marks for diagnostics: lsp/error, lsp/warning, and lsp/note.
static NSString* const kMarkTypePrefix = @"lsp/";

static std::vector<unichar> Characters (NSString* str)
{
	std::vector<unichar> res(str.length);
	[str getCharacters:res.data() range:NSMakeRange(0, res.size())];
	return res;
}

// The change from one text to another, as an incremental change: the range of
// the old text between their common start and end (as the protocol counts,
// in lines and UTF-16 code units), and the new text for it.
static NSDictionary* ContentChange (NSString* oldText, NSString* newText)
{
	std::vector<unichar> const from = Characters(oldText), to = Characters(newText);

	size_t start = 0;
	while(start < from.size() && start < to.size() && from[start] == to[start])
		++start;
	size_t end = 0;
	while(end < from.size() - start && end < to.size() - start && from[from.size() - end - 1] == to[to.size() - end - 1])
		++end;

	// Not between the two halves of a surrogate pair.
	if(start && CFStringIsSurrogateHighCharacter(from[start - 1]))
		--start;
	if(end && CFStringIsSurrogateLowCharacter(from[from.size() - end]))
		--end;

	auto position = [&](size_t index){
		size_t line = 0, lineStart = 0;
		for(size_t i = 0; i < index; ++i)
		{
			if(from[i] == '\n')
			{
				++line;
				lineStart = i + 1;
			}
		}
		return @{ @"line": @(line), @"character": @(index - lineStart) };
	};

	return @{
		@"range": @{ @"start": position(start), @"end": position(from.size() - end) },
		@"text":  [newText substringWithRange:NSMakeRange(start, to.size() - end - start)],
	};
}

// The lines two texts have in common, as pairs of their indices in order,
// found with Myers’ algorithm: equal(x, y) tells whether line x of the first
// is line y of the second. After too many changes, none.
template <typename Equal>
static std::vector<std::pair<int, int>> CommonLines (int n, int m, Equal const& equal)
{
	// For each number of changes d (lines removed or added), how far the paths
	// with d changes get in the first text along each diagonal k (x - y).
	int const max = n + m;
	std::vector<int> v(2 * max + 3, 0);
	auto V = [&](int k) -> int& { return v[k + max + 1]; };
	std::vector<std::vector<int>> reached; // reached[d][k + d]
	int changes = -1;
	for(int d = 0; d <= max && d <= 1000 && changes == -1; ++d)
	{
		for(int k = -d; k <= d; k += 2)
		{
			int x = k == -d || (k != d && V(k - 1) < V(k + 1)) ? V(k + 1) : V(k - 1) + 1;
			for(int y = x - k; x < n && y < m && equal(x, y); ++x, ++y)
				;
			V(k) = x;
			if(x >= n && x - k >= m)
				changes = d;
		}
		reached.emplace_back(v.begin() + max + 1 - d, v.begin() + max + 2 + d);
	}

	std::vector<std::pair<int, int>> res;
	if(changes == -1)
		return res;

	int x = n, y = m;
	for(int d = changes; d > 0; --d)
	{
		int const k = x - y;
		auto R = [&](int diagonal) { return reached[d - 1][diagonal + d - 1]; };
		int const previousK = k == -d || (k != d && R(k - 1) < R(k + 1)) ? k + 1 : k - 1;
		int const previousX = R(previousK), previousY = previousX - previousK;
		for(; x > previousX && y > previousY; --x, --y)
			res.emplace_back(x - 1, y - 1);
		x = previousX, y = previousY;
	}
	for(; x > 0 && y > 0; --x, --y)
		res.emplace_back(x - 1, y - 1);
	std::reverse(res.begin(), res.end());
	return res;
}

// The replacements (byte ranges of one text, and their new text) that turn it
// into another, line by line: the lines they have in common stay as they are,
// as do the start and end of the others, so that the caret and marks on them
// stay where they are. Servers such as ruby-lsp format a document by
// replacing all of it.
static std::vector<std::pair<std::pair<size_t, size_t>, std::string>> LineReplacements (std::string const& from, std::string const& to)
{
	auto lines = [](std::string const& str){
		std::vector<std::string_view> res;
		for(size_t bol = 0; bol < str.size(); )
		{
			size_t eol = str.find('\n', bol);
			eol = eol == std::string::npos ? str.size() : eol + 1;
			res.emplace_back(str.data() + bol, eol - bol);
			bol = eol;
		}
		return res;
	};

	auto trimmed = [](std::string_view line){
		size_t const first = line.find_first_not_of(" \t\r\n");
		return first == std::string_view::npos ? std::string_view() : line.substr(first, line.find_last_not_of(" \t\r\n") - first + 1);
	};

	std::vector<std::string_view> const a = lines(from), b = lines(to);
	int const n = a.size(), m = b.size();

	// The lines in common and, between them, the lines that are the same but
	// for white space (such as lines indented again, when blank lines were
	// also removed), followed by the ends of both texts.
	std::vector<std::pair<int, int>> common = CommonLines(n, m, [&](int x, int y){ return a[x] == b[y]; }), paired;
	common.emplace_back(n, m);
	int i = 0, j = 0;
	for(auto const& [nextI, nextJ] : common)
	{
		for(auto const& [x, y] : CommonLines(nextI - i, nextJ - j, [&](int p, int q){ return trimmed(a[i + p]) == trimmed(b[j + q]); }))
			paired.emplace_back(i + x, j + y);
		paired.emplace_back(nextI, nextJ);
		i = nextI + 1, j = nextJ + 1;
	}

	std::vector<size_t> aStart = { 0 }, bStart = { 0 };
	for(auto const& line : a)
		aStart.push_back(aStart.back() + line.size());
	for(auto const& line : b)
		bStart.push_back(bStart.back() + line.size());

	// The old and new text of changed lines, without what they start and end
	// with in common (and not in the middle of a UTF-8 sequence).
	auto continuation = [](std::string const& str, size_t i){ return i < str.size() && (str[i] & 0xC0) == 0x80; };
	std::vector<std::pair<std::pair<size_t, size_t>, std::string>> res;
	auto replace = [&](size_t fromStart, size_t fromEnd, size_t toStart, size_t toEnd){
		size_t const start = fromStart, end = fromEnd;
		for(; fromStart < fromEnd && toStart < toEnd && from[fromStart] == to[toStart]; ++fromStart, ++toStart)
			;
		for(; fromStart > start && (continuation(from, fromStart) || continuation(to, toStart)); --fromStart, --toStart)
			;
		for(; fromStart < fromEnd && toStart < toEnd && from[fromEnd - 1] == to[toEnd - 1]; --fromEnd, --toEnd)
			;
		for(; fromEnd < end && continuation(from, fromEnd); ++fromEnd, ++toEnd)
			;
		if(fromStart != fromEnd || toStart != toEnd)
			res.emplace_back(std::make_pair(fromStart, fromEnd), to.substr(toStart, toEnd - toStart));
	};

	// The paired lines (which may differ in white space), and between them,
	// each run of other lines, or each of its lines, when it has as many lines
	// as it had.
	i = 0, j = 0;
	for(auto const& [nextI, nextJ] : paired)
	{
		if(nextI - i == nextJ - j)
		{
			for(; i < nextI; ++i, ++j)
				replace(aStart[i], aStart[i + 1], bStart[j], bStart[j + 1]);
		}
		else
		{
			replace(aStart[i], aStart[nextI], bStart[j], bStart[nextJ]);
		}
		if(nextI < n)
			replace(aStart[nextI], aStart[nextI + 1], bStart[nextJ], bStart[nextJ + 1]);
		i = nextI + 1, j = nextJ + 1;
	}
	return res;
}

// How a server wants changes to documents: 0 not at all, 1 as whole texts,
// and 2 incrementally; or -1 before it is initialized.
static int SyncKind (LSPServer* server)
{
	if(!server.capabilities)
		return -1;
	id sync = server.capabilities[@"textDocumentSync"];
	id kind = [sync isKindOfClass:[NSDictionary class]] ? sync[@"change"] : sync;
	return [kind isKindOfClass:[NSNumber class]] ? [kind intValue] : 1;
}

// What a server knows about a document.
@interface LSPDocument : NSObject
@property (nonatomic) LSPServer* server;
@property (nonatomic) NSString* serverKey;
@property (nonatomic) NSString* uri;
@property (nonatomic) NSInteger version;
@property (nonatomic) NSString* text; // As sent to the server
@property (nonatomic) NSTimer* changeTimer;
@property (nonatomic) BOOL hasChangesToSend; // Once the server is initialized
@property (nonatomic) NSTimer* diagnosticsTimer;
@property (nonatomic) BOOL awaitingDiagnostics;
@property (nonatomic) BOOL needsDiagnostics; // Once those awaited are answered
@end

@implementation LSPDocument
@end

@interface LSPClient ()
{
	NSMutableDictionary<NSString*, LSPServer*>* _servers; // By command and root folder
	NSMutableDictionary<NSString*, LSPFileWatcher*>* _fileWatchers;
	NSMutableDictionary<NSString*, NSTimer*>* _idleTimers;
	NSMutableDictionary<NSString*, NSDate*>* _exitDates;
	NSMutableDictionary<NSString*, NSMutableSet<NSString*>*>* _diagnosedPaths;
	NSMutableDictionary<NSString*, NSArray*>* _diagnostics; // The latest, by path
	NSMutableDictionary<NSUUID*, LSPDocument*>* _documents;
	NSMutableSet<NSUUID*>* _documentsWithoutServer;
}
@end

@implementation LSPClient
+ (instancetype)sharedInstance
{
	static LSPClient* sharedInstance = [self new];
	return sharedInstance;
}

- (instancetype)init
{
	if(self = [super init])
	{
		_servers                = [NSMutableDictionary dictionary];
		_fileWatchers           = [NSMutableDictionary dictionary];
		_idleTimers             = [NSMutableDictionary dictionary];
		_exitDates              = [NSMutableDictionary dictionary];
		_diagnosedPaths         = [NSMutableDictionary dictionary];
		_diagnostics            = [NSMutableDictionary dictionary];
		_documents              = [NSMutableDictionary dictionary];
		_documentsWithoutServer = [NSMutableSet set];

		NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
		[center addObserver:self selector:@selector(documentDidLoad:)          name:OakDocumentDidLoadNotification          object:nil];
		[center addObserver:self selector:@selector(documentContentDidChange:) name:OakDocumentContentDidChangeNotification object:nil];
		[center addObserver:self selector:@selector(documentDidSave:)          name:OakDocumentDidSaveNotification          object:nil];
		[center addObserver:self selector:@selector(documentWillClose:)        name:OakDocumentWillCloseNotification        object:nil];
		[center addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:NSApp];

		for(OakDocument* document in OakDocumentController.sharedInstance.documents)
			[self openDocument:document];
	}
	return self;
}

- (void)applicationWillTerminate:(NSNotification*)aNotification
{
	for(LSPServer* server in _servers.allValues)
		[server shutDownAndWait];
	[_servers removeAllObjects];
}

// =================
// = Notifications =
// =================

- (void)documentDidLoad:(NSNotification*)aNotification
{
	OakDocument* document = aNotification.object;
	[_documentsWithoutServer removeObject:document.identifier];
	[self openDocument:document];
}

- (void)documentContentDidChange:(NSNotification*)aNotification
{
	OakDocument* document = aNotification.object;
	LSPDocument* state = _documents[document.identifier];
	if(!state)
		return [self openDocument:document];

	if(!state.server.isRunning)
	{
		[self closeDocument:document];
		return [self openDocument:document];
	}

	// Incremental changes are sent right away (together, for those made at
	// once), and whole texts once typing pauses.
	[state.changeTimer invalidate];
	state.changeTimer = [NSTimer scheduledTimerWithTimeInterval:SyncKind(state.server) == 2 ? 0 : kChangeDelay target:self selector:@selector(changeTimerDidFire:) userInfo:document repeats:NO];
}

- (void)changeTimerDidFire:(NSTimer*)aTimer
{
	[self sendChangesForDocument:aTimer.userInfo];
}

// A new path (Save As) or file type needs another server, or none.
- (void)documentDidSave:(NSNotification*)aNotification
{
	OakDocument* document = aNotification.object;
	[_documentsWithoutServer removeObject:document.identifier];

	LSPDocument* state = _documents[document.identifier];
	if(state && (!state.server.isRunning || ![state.uri isEqualToString:LSPURIForPath(document.path)]))
	{
		[self closeDocument:document];
		state = nil;
	}

	if(!state)
		return [self openDocument:document];

	if(state.changeTimer || state.hasChangesToSend)
		[self sendChangesForDocument:document];
	[state.server sendNotification:@"textDocument/didSave" params:@{ @"textDocument": @{ @"uri": state.uri } }];
}

- (void)documentWillClose:(NSNotification*)aNotification
{
	[self closeDocument:aNotification.object];
}

// =============
// = Documents =
// =============

- (void)openDocument:(OakDocument*)document
{
	if(!document.isLoaded || _documents[document.identifier] || [_documentsWithoutServer containsObject:document.identifier])
		return;

	NSString* key;
	NSString* languageId;
	BOOL hasServer;
	LSPServer* server = [self serverForDocument:document key:&key languageId:&languageId hasServer:&hasServer];
	if(!server)
	{
		if(!hasServer)
			[_documentsWithoutServer addObject:document.identifier];
		return;
	}

	LSPDocument* state = [[LSPDocument alloc] init];
	state.server    = server;
	state.serverKey = key;
	state.uri       = LSPURIForPath(document.path);
	state.version   = 1;
	state.text      = document.content ?: @"";
	_documents[document.identifier] = state;

	[server sendNotification:@"textDocument/didOpen" params:@{
		@"textDocument": @{
			@"uri":        state.uri,
			@"languageId": languageId,
			@"version":    @(state.version),
			@"text":       state.text,
		}
	}];
	[self pullDiagnosticsForDocument:document.identifier];
}

// Changes are held back until the server is initialized, and how it wants
// them is known. Servers with incremental sync get the changed range, as some
// (such as ruby-lsp) need it, and others the whole text.
- (void)sendChangesForDocument:(OakDocument*)document
{
	LSPDocument* state = _documents[document.identifier];
	[state.changeTimer invalidate];
	state.changeTimer = nil;
	if(!state || !state.server.isRunning)
		return;

	int const kind = SyncKind(state.server);
	state.hasChangesToSend = kind == -1;
	if(kind <= 0)
		return;

	NSString* text = document.content ?: @"";
	if([text isEqualToString:state.text])
		return;

	NSDictionary* change = kind == 2 ? ContentChange(state.text, text) : @{ @"text": text };
	state.text     = text;
	state.version += 1;
	[state.server sendNotification:@"textDocument/didChange" params:@{
		@"textDocument":   @{ @"uri": state.uri, @"version": @(state.version) },
		@"contentChanges": @[ change ],
	}];
	[self scheduleDiagnosticsForDocument:document.identifier];
}

- (void)closeDocument:(OakDocument*)document
{
	[_documentsWithoutServer removeObject:document.identifier];

	LSPDocument* state = _documents[document.identifier];
	if(!state)
		return;

	[state.changeTimer invalidate];
	[state.diagnosticsTimer invalidate];
	[_documents removeObjectForKey:document.identifier];
	[document removeAllMarksOfType:kMarkTypePrefix];

	if(state.server.isRunning)
	{
		[state.server sendNotification:@"textDocument/didClose" params:@{ @"textDocument": @{ @"uri": state.uri } }];
		[self stopServerWhenIdle:state.serverKey];
	}
}

// ============
// = Requests =
// ============

- (BOOL)hasServerForDocument:(OakDocument*)document
{
	return _documents[document.identifier].server.isRunning;
}

- (BOOL)sendRequest:(NSString*)method params:(NSDictionary*)params document:(OakDocument*)document position:(text::pos_t const&)position handler:(void(^)(id result, NSDictionary* error))handler
{
	// Edits (as servers ask clients to apply them) are applied by TextMate.
	if([method isEqualToString:@"workspace/applyEdit"])
	{
		handler([self applyEditRequest:params], nil);
		return YES;
	}

	if(!document)
		return NO;

	LSPDocument* state = _documents[document.identifier];
	if(!state || !state.server.isRunning)
	{
		[self closeDocument:document];
		[self openDocument:document];
		if(!(state = _documents[document.identifier]))
			return NO;
	}

	if(state.changeTimer || state.hasChangesToSend)
		[self sendChangesForDocument:document];

	// Servers can answer requests for what they do not do with nothing, as if
	// there were nothing to do (ruby-lsp formats nothing without a formatter),
	// so those fail here, as requests of unknown methods do. Formatting also
	// fails while the server is starting (which can take a while, such as when
	// ruby-lsp installs its bundle), rather than holding up a save.
	static NSDictionary<NSString*, NSString*>* const providers = @{
		@"textDocument/formatting":      @"documentFormattingProvider",
		@"textDocument/rangeFormatting": @"documentRangeFormattingProvider",
	};
	if(NSString* provider = providers[method])
	{
		id capability = state.server.capabilities[provider];
		if(!state.server.capabilities)
		{
			handler(nil, @{ @"code": @(-32002), @"message": @"The language server of this document is starting." });
			return YES;
		}
		else if(!capability || capability == NSNull.null || ([capability isKindOfClass:[NSNumber class]] && ![capability boolValue]))
		{
			handler(nil, @{ @"code": @(-32601), @"message": @"The language server of this document does not format documents." });
			return YES;
		}
	}

	// Requests not about a document (such as workspace/symbol or
	// codeAction/resolve) go to the document’s server, as they are.
	NSMutableDictionary* request = [params mutableCopy] ?: [NSMutableDictionary dictionary];
	if(![method hasPrefix:@"textDocument/"])
	{
		[state.server sendRequest:method params:request handler:handler];
		return YES;
	}

	if(!request[@"textDocument"])
		request[@"textDocument"] = @{ @"uri": state.uri };
	if([method isEqualToString:@"textDocument/codeAction"])
	{
		// Actions for the position’s line, with its diagnostics as context.
		if(!request[@"range"] && position != text::pos_t::undefined)
			request[@"range"] = @{ @"start": @{ @"line": @(position.line), @"character": @0 }, @"end": @{ @"line": @(position.line + 1), @"character": @0 } };
		if(!request[@"context"])
			request[@"context"] = @{ @"diagnostics": [self diagnosticsForPath:document.path inRange:request[@"range"]] };
	}
	else if(position != text::pos_t::undefined)
	{
		request[@"position"] = [self serverPositionForDocument:document position:position];
	}

	[state.server sendRequest:method params:request handler:handler];
	return YES;
}

// A position with a byte offset (as TextMate has it) as one with a UTF-16 offset.
- (NSDictionary*)serverPositionForDocument:(OakDocument*)document position:(text::pos_t const&)position
{
	NSUInteger character = 0;
	NSArray<NSString*>* lines = [document.content componentsSeparatedByString:@"\n"];
	if(position.line < lines.count)
	{
		NSData* line = [lines[position.line] dataUsingEncoding:NSUTF8StringEncoding];
		character = [[NSString alloc] initWithBytes:line.bytes length:MIN(position.column, line.length) encoding:NSUTF8StringEncoding].length;
	}
	return @{ @"line": @(position.line), @"character": @(character) };
}

- (NSArray<NSString*>*)completionsForDocument:(OakDocument*)document wordStart:(text::pos_t const&)wordStart position:(text::pos_t const&)position timeout:(NSTimeInterval)timeout
{
	__block id response;
	__block BOOL done = NO;
	BOOL sent = [self sendRequest:@"textDocument/completion" params:@{ } document:document position:position handler:^(id result, NSDictionary* error){
		response = result;
		done = YES;
	}];
	if(!sent)
		return nil;

	// The server’s messages arrive on the main queue, which the run loop runs.
	NSDate* limit = [NSDate dateWithTimeIntervalSinceNow:timeout];
	while(!done && limit.timeIntervalSinceNow > 0)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, MIN(limit.timeIntervalSinceNow, 0.05), true);

	NSArray* items = [response isKindOfClass:[NSDictionary class]] ? response[@"items"] : response;
	if(![items isKindOfClass:[NSArray class]])
		return nil;

	NSMutableArray* sorted = [NSMutableArray array];
	for(NSDictionary* item in items)
	{
		if([item isKindOfClass:[NSDictionary class]] && [item[@"label"] isKindOfClass:[NSString class]])
			[sorted addObject:item];
	}
	[sorted sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary* lhs, NSDictionary* rhs){
		NSString* left  = [lhs[@"sortText"] isKindOfClass:[NSString class]] ? lhs[@"sortText"] : lhs[@"label"];
		NSString* right = [rhs[@"sortText"] isKindOfClass:[NSString class]] ? rhs[@"sortText"] : rhs[@"label"];
		return [left compare:right];
	}];

	// The caret’s line, and where the word starts in it, as the server counts.
	NSArray<NSString*>* lines = [document.content componentsSeparatedByString:@"\n"];
	NSString* line = position.line < lines.count ? lines[position.line] : @"";
	NSUInteger wordStartCharacter = MIN([[self serverPositionForDocument:document position:wordStart][@"character"] unsignedIntegerValue], line.length);

	// The name of an item such as “map(enumerable, fun)”, completed as a word.
	NSCharacterSet* nameEnd = [NSCharacterSet characterSetWithCharactersInString:@"( "];
	NSMutableOrderedSet* words = [NSMutableOrderedSet orderedSet];
	for(NSDictionary* item in sorted)
	{
		NSString* name = [item[@"filterText"] isKindOfClass:[NSString class]] ? item[@"filterText"] : item[@"label"];

		// For an edit (a text edit, or an insert and replace edit) of the line,
		// the word it makes, if it leaves the text before the word as it is.
		NSDictionary* edit = [item[@"textEdit"] isKindOfClass:[NSDictionary class]] ? item[@"textEdit"] : nil;
		NSDictionary* range = [edit[@"range"] isKindOfClass:[NSDictionary class]] ? edit[@"range"] : edit[@"insert"];
		if([edit[@"newText"] isKindOfClass:[NSString class]] && [range isKindOfClass:[NSDictionary class]])
		{
			NSUInteger start = [range[@"start"][@"character"] unsignedIntegerValue];
			if([range[@"start"][@"line"] unsignedIntegerValue] != position.line || start > line.length)
				continue;

			NSString* newText = edit[@"newText"];
			if([item[@"insertTextFormat"] intValue] == 2) // A snippet, up to its first placeholder
				newText = [newText componentsSeparatedByString:@"$"].firstObject;

			NSString* edited = [[line substringToIndex:start] stringByAppendingString:newText];
			if(edited.length < wordStartCharacter || ![[edited substringToIndex:wordStartCharacter] isEqualToString:[line substringToIndex:wordStartCharacter]])
				continue;
			name = [edited substringFromIndex:wordStartCharacter];
		}

		name = [name componentsSeparatedByCharactersInSet:nameEnd].firstObject;
		if(name.length)
			[words addObject:name];
	}
	return words.array;
}

// ===========
// = Servers =
// ===========

// The server for a document, started if needed. Without one, hasServer tells
// whether there is none (the document can be skipped until it is loaded or
// saved again) or it exited recently (it will be tried again).
- (LSPServer*)serverForDocument:(OakDocument*)document key:(NSString**)keyOut languageId:(NSString**)languageIdOut hasServer:(BOOL*)hasServer
{
	*hasServer = NO;
	if(!document.path || !document.fileType)
		return nil;

	scope::scope_t const scope(to_s(document.fileType));
	bundles::item_ptr item;
	plist::any_t const setting = bundles::value_for_setting("languageServer", scope, &item);

	std::string command, languageId;
	if(!item || !plist::get_key_path(setting, "command", command))
		return nil;
	plist::get_key_path(setting, "languageId", languageId);

	bool preferOuterRoot = false;
	plist::get_key_path(setting, "preferOuterRoot", preferOuterRoot);

	std::vector<std::string> rootFiles;
	plist::array_t array;
	if(plist::get_key_path(setting, "rootFiles", array))
	{
		for(auto const& value : array)
		{
			if(std::string const* str = boost::get<std::string>(&value))
				rootFiles.push_back(*str);
		}
	}

	NSString* root = [self rootForPath:document.path rootFiles:rootFiles preferOuterRoot:preferOuterRoot];
	if(!root)
		return nil;

	std::map<std::string, std::string> environment = oak::basic_environment();
	environment << document.variables << item->bundle_variables();
	environment = bundles::scope_variables(environment, scope);
	environment = variables_for_path(environment, to_s(document.path), scope, to_s(document.path.stringByDeletingLastPathComponent));

	auto disabled = environment.find("TM_DISABLE_LANGUAGE_SERVER");
	if(disabled != environment.end() && disabled->second != "" && disabled->second != "0" && disabled->second != "false")
		return nil;

	*hasServer = YES;
	NSString* key = [NSString stringWithFormat:@"%@\n%@", to_ns(command), root];
	LSPServer* server = _servers[key];
	if(!server)
	{
		NSDate* exitDate = _exitDates[key];
		if(exitDate && -exitDate.timeIntervalSinceNow < kRestartDelay)
			return nil;

		server = [[LSPServer alloc] initWithCommand:to_ns(command) rootURL:[NSURL fileURLWithPath:root isDirectory:YES] environment:environment];

		__weak LSPClient* weakSelf = self;
		__weak LSPServer* weakServer = server;
		server.notificationHandler = ^(NSString* method, id params){
			[weakSelf server:weakServer key:key didSendNotification:method params:params];
		};
		server.terminationHandler = ^(int status){
			[weakSelf serverDidExit:weakServer key:key];
		};
		server.requestHandler = ^id(NSString* method, id params){
			return [weakSelf server:weakServer key:key didSendRequest:method params:params];
		};
		server.initializationHandler = ^{
			[weakSelf serverDidInitialize:weakServer];
		};

		if(![server start])
		{
			_exitDates[key] = NSDate.date;
			return nil;
		}
		_servers[key] = server;
	}

	[_idleTimers[key] invalidate];
	[_idleTimers removeObjectForKey:key];

	*keyOut = key;
	*languageIdOut = languageId.empty() ? document.fileType.pathExtension : to_ns(languageId);
	return server;
}

// The closest folder of the path with one of the root files, or the next one
// up with preferOuterRoot. Without root files, the path’s folder.
- (NSString*)rootForPath:(NSString*)path rootFiles:(std::vector<std::string> const&)rootFiles preferOuterRoot:(BOOL)preferOuterRoot
{
	if(rootFiles.empty())
		return path.stringByDeletingLastPathComponent;

	NSMutableArray<NSString*>* roots = [NSMutableArray array];
	for(NSString* dir = path.stringByDeletingLastPathComponent; dir.length > 1 && roots.count < (preferOuterRoot ? 2 : 1); dir = dir.stringByDeletingLastPathComponent)
	{
		for(auto const& file : rootFiles)
		{
			if([NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:to_ns(file)]])
			{
				[roots addObject:dir];
				break;
			}
		}
	}
	return roots.lastObject;
}

- (void)stopServerWhenIdle:(NSString*)key
{
	for(LSPDocument* state in _documents.allValues)
	{
		if([state.serverKey isEqualToString:key])
			return;
	}

	[_idleTimers[key] invalidate];
	_idleTimers[key] = [NSTimer scheduledTimerWithTimeInterval:kIdleShutDownDelay target:self selector:@selector(idleTimerDidFire:) userInfo:key repeats:NO];
}

- (void)idleTimerDidFire:(NSTimer*)aTimer
{
	NSString* key = aTimer.userInfo;
	[_idleTimers removeObjectForKey:key];

	LSPServer* server = _servers[key];
	[_servers removeObjectForKey:key];
	[self clearDiagnosticsForKey:key];
	[self stopWatchingFilesForKey:key];
	[server shutDown];
}

// A server that exits by itself is not started again for a while. Its
// documents are opened with the next one.
- (void)serverDidExit:(LSPServer*)server key:(NSString*)key
{
	if(!server || _servers[key] != server)
		return;

	[_servers removeObjectForKey:key];
	_exitDates[key] = NSDate.date;
	[self clearDiagnosticsForKey:key];
	[self stopWatchingFilesForKey:key];

	for(NSUUID* identifier in _documents.allKeys)
	{
		if(_documents[identifier].server == server)
		{
			[_documents[identifier].changeTimer invalidate];
			[_documents[identifier].diagnosticsTimer invalidate];
			[_documents removeObjectForKey:identifier];
		}
	}
}

// Requests from a server that TextMate answers: edits to apply, files to
// watch, and diagnostics to ask for again.
- (id)server:(LSPServer*)server key:(NSString*)key didSendRequest:(NSString*)method params:(id)params
{
	if(!server || _servers[key] != server)
		return nil;

	NSDictionary* dictionary = [params isKindOfClass:[NSDictionary class]] ? params : @{ };
	if([method isEqualToString:@"workspace/applyEdit"])
	{
		return [self applyEditRequest:dictionary];
	}
	else if([method isEqualToString:@"client/registerCapability"] || [method isEqualToString:@"client/unregisterCapability"])
	{
		BOOL add = [method isEqualToString:@"client/registerCapability"];
		NSArray* registrations = dictionary[add ? @"registrations" : @"unregisterations"]; // Sic
		for(NSDictionary* registration in [registrations isKindOfClass:[NSArray class]] ? registrations : @[ ])
		{
			if(![registration isKindOfClass:[NSDictionary class]] || ![registration[@"method"] isEqual:@"workspace/didChangeWatchedFiles"])
				continue;

			NSString* identifier = [registration[@"id"] description];
			NSDictionary* options = [registration[@"registerOptions"] isKindOfClass:[NSDictionary class]] ? registration[@"registerOptions"] : nil;
			if(add && [options[@"watchers"] isKindOfClass:[NSArray class]])
				[[self fileWatcherForServer:server key:key] addWatchers:options[@"watchers"] identifier:identifier];
			else if(!add)
				[_fileWatchers[key] removeWatchersWithIdentifier:identifier];
		}
	}
	else if([method isEqualToString:@"workspace/diagnostic/refresh"])
	{
		[self pullDiagnosticsForServer:server];
	}
	else
	{
		return nil;
	}
	return NSNull.null;
}

// ==================
// = Watching Files =
// ==================

- (LSPFileWatcher*)fileWatcherForServer:(LSPServer*)server key:(NSString*)key
{
	if(!_fileWatchers[key])
	{
		__weak LSPServer* weakServer = server;
		_fileWatchers[key] = [[LSPFileWatcher alloc] initWithRootPath:server.rootURL.path handler:^(NSArray<NSDictionary*>* changes){
			[weakServer sendNotification:@"workspace/didChangeWatchedFiles" params:@{ @"changes": changes }];
		}];
	}
	return _fileWatchers[key];
}

- (void)stopWatchingFilesForKey:(NSString*)key
{
	[_fileWatchers[key] stop];
	[_fileWatchers removeObjectForKey:key];
}

// ===============
// = Diagnostics =
// ===============

// Servers with a diagnostic provider are asked for a document’s diagnostics
// (when it is opened, and once typing pauses) rather than sending them.
- (void)scheduleDiagnosticsForDocument:(NSUUID*)identifier
{
	LSPDocument* state = _documents[identifier];
	[state.diagnosticsTimer invalidate];
	state.diagnosticsTimer = [NSTimer scheduledTimerWithTimeInterval:kChangeDelay target:self selector:@selector(diagnosticsTimerDidFire:) userInfo:identifier repeats:NO];
}

- (void)diagnosticsTimerDidFire:(NSTimer*)aTimer
{
	[self pullDiagnosticsForDocument:aTimer.userInfo];
}

// One request at a time: ruby-lsp, for one, answers with the text it has
// when a request arrives, which lacks edits sent before it that wait behind
// requests being answered.
- (void)pullDiagnosticsForDocument:(NSUUID*)identifier
{
	LSPDocument* state = _documents[identifier];
	[state.diagnosticsTimer invalidate];
	state.diagnosticsTimer = nil;
	if(!state.server.isRunning || ![state.server.capabilities[@"diagnosticProvider"] isKindOfClass:[NSDictionary class]])
		return;

	state.needsDiagnostics = state.awaitingDiagnostics;
	if(state.awaitingDiagnostics)
		return;

	__weak LSPClient* weakSelf = self;
	__weak LSPDocument* weakState = state;
	NSInteger version = state.version;
	state.awaitingDiagnostics = YES;
	[state.server sendRequest:@"textDocument/diagnostic" params:@{ @"textDocument": @{ @"uri": state.uri } } handler:^(id result, NSDictionary* error){
		[weakSelf document:identifier state:weakState version:version didPullDiagnostics:result error:error];
	}];
}

// Documents opened before the server was initialized get their changes
// since, if any, and their diagnostics.
- (void)serverDidInitialize:(LSPServer*)server
{
	for(NSUUID* identifier in _documents.allKeys)
	{
		LSPDocument* state = _documents[identifier];
		if(state.server != server)
			continue;

		OakDocument* document = [OakDocumentController.sharedInstance findDocumentWithIdentifier:identifier];
		if(state.hasChangesToSend && document)
				[self sendChangesForDocument:document];
		else	[self pullDiagnosticsForDocument:identifier];
	}
}

- (void)pullDiagnosticsForServer:(LSPServer*)server
{
	for(NSUUID* identifier in _documents)
	{
		if(_documents[identifier].server == server)
			[self pullDiagnosticsForDocument:identifier];
	}
}

- (void)document:(NSUUID*)identifier state:(LSPDocument*)state version:(NSInteger)version didPullDiagnostics:(id)result error:(NSDictionary*)error
{
	if(!state || _documents[identifier] != state)
		return;

	state.awaitingDiagnostics = NO;
	if(state.needsDiagnostics)
	{
		state.needsDiagnostics = NO;
		[self scheduleDiagnosticsForDocument:identifier];
	}

	// Diagnostics for an older version, or with newer changes still to be
	// sent, are followed by others.
	if(error || state.version != version || state.changeTimer || state.hasChangesToSend)
		return;

	NSDictionary* report = [result isKindOfClass:[NSDictionary class]] ? result : nil;
	if([report[@"kind"] isEqual:@"unchanged"])
		return;

	NSArray* items = [report[@"items"] isKindOfClass:[NSArray class]] ? report[@"items"] : @[ ];
	[self publishDiagnostics:@{ @"uri": state.uri, @"diagnostics": items } key:state.serverKey];
}

- (void)server:(LSPServer*)server key:(NSString*)key didSendNotification:(NSString*)method params:(id)params
{
	if(server && _servers[key] == server && [method isEqualToString:@"textDocument/publishDiagnostics"] && [params isKindOfClass:[NSDictionary class]])
		[self publishDiagnostics:params key:key];
}

// Diagnostics replace a document’s marks, also for documents that are not
// open (they are shown when it is).
- (void)publishDiagnostics:(NSDictionary*)params key:(NSString*)key
{
	NSURL* url = [params[@"uri"] isKindOfClass:[NSString class]] ? [NSURL URLWithString:params[@"uri"]] : nil;
	NSArray* diagnostics = params[@"diagnostics"];
	if(!url.isFileURL || !url.path || ![diagnostics isKindOfClass:[NSArray class]])
		return;

	_diagnostics[url.path] = diagnostics.count ? diagnostics : nil;

	OakDocument* document = [OakDocumentController.sharedInstance documentWithPath:url.path];
	[document removeAllMarksOfType:kMarkTypePrefix];

	// Servers can report a problem twice, e.g. when checking a saved file.
	NSMutableSet* seen = [NSMutableSet set];

	NSArray<NSString*>* lines = document.isLoaded ? [document.content componentsSeparatedByString:@"\n"] : nil;
	for(NSDictionary* diagnostic in diagnostics)
	{
		if(![diagnostic isKindOfClass:[NSDictionary class]] || ![diagnostic[@"message"] isKindOfClass:[NSString class]] || [seen containsObject:diagnostic])
			continue;
		[seen addObject:diagnostic];

		NSDictionary* start = diagnostic[@"range"][@"start"];
		NSUInteger line = [start[@"line"] unsignedIntegerValue], column = 0;
		if(line < lines.count)
		{
			NSString* text = lines[line];
			NSUInteger character = MIN([start[@"character"] unsignedIntegerValue], text.length);
			column = [[text substringToIndex:character] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
		}

		NSString* type;
		switch([diagnostic[@"severity"] intValue])
		{
			case 2:  type = @"warning"; break;
			case 3:  type = @"note";    break;
			case 4:  type = @"note";    break;
			default: type = @"error";   break;
		}

		[document setMarkOfType:[kMarkTypePrefix stringByAppendingString:type] atPosition:text::pos_t(line, column) content:diagnostic[@"message"]];
	}

	NSMutableSet* paths = _diagnosedPaths[key];
	if(!paths)
		_diagnosedPaths[key] = paths = [NSMutableSet set];
	if(diagnostics.count)
			[paths addObject:url.path];
	else	[paths removeObject:url.path];
}

// The diagnostics of a file on the lines of a range.
- (NSArray*)diagnosticsForPath:(NSString*)path inRange:(NSDictionary*)range
{
	NSInteger first = [range[@"start"][@"line"] integerValue], last = [range[@"end"][@"line"] integerValue];
	if([range[@"end"][@"character"] integerValue] == 0 && first < last)
		--last;

	NSMutableArray* res = [NSMutableArray array];
	for(NSDictionary* diagnostic in _diagnostics[path])
	{
		NSInteger start = [diagnostic[@"range"][@"start"][@"line"] integerValue], end = [diagnostic[@"range"][@"end"][@"line"] integerValue];
		if(start <= last && first <= end)
			[res addObject:diagnostic];
	}
	return res;
}

- (void)clearDiagnosticsForKey:(NSString*)key
{
	for(NSString* path in _diagnosedPaths[key])
	{
		[[OakDocumentController.sharedInstance documentWithPath:path] removeAllMarksOfType:kMarkTypePrefix];
		[_diagnostics removeObjectForKey:path];
	}
	[_diagnosedPaths removeObjectForKey:key];
}
// =========
// = Edits =
// =========

// A workspace/applyEdit request, applied: its result.
- (NSDictionary*)applyEditRequest:(NSDictionary*)params
{
	NSString* failure = [self applyWorkspaceEdit:params[@"edit"]];
	return failure ? @{ @"applied": @NO, @"failureReason": failure } : @{ @"applied": @YES };
}

// Applies the text edits of a workspace edit to documents, as Find in Project
// replaces: in open documents (which can be undone) and in files that are not
// open (which are saved). Returns why it could not, or nil.
- (NSString*)applyWorkspaceEdit:(NSDictionary*)edit
{
	if(![edit isKindOfClass:[NSDictionary class]])
		return @"There is no edit.";

	NSMutableDictionary<NSString*, NSMutableArray*>* editsByURI = [NSMutableDictionary dictionary];
	if([edit[@"changes"] isKindOfClass:[NSDictionary class]])
	{
		for(NSString* uri in edit[@"changes"])
			[editsByURI[uri] ?: (editsByURI[uri] = [NSMutableArray array]) addObjectsFromArray:edit[@"changes"][uri]];
	}
	if([edit[@"documentChanges"] isKindOfClass:[NSArray class]])
	{
		for(NSDictionary* change in edit[@"documentChanges"])
		{
			NSString* uri = change[@"textDocument"][@"uri"];
			if(!uri || ![change[@"edits"] isKindOfClass:[NSArray class]])
				return @"TextMate does not create, rename, or delete files.";
			[editsByURI[uri] ?: (editsByURI[uri] = [NSMutableArray array]) addObjectsFromArray:change[@"edits"]];
		}
	}

	// Check all files before changing any.
	std::vector<std::tuple<OakDocument*, std::multimap<std::pair<size_t, size_t>, std::string>, uint32_t>> changes;
	for(NSString* uri in editsByURI)
	{
		NSURL* url = [NSURL URLWithString:uri];
		if(!url.isFileURL || !url.path)
			return [NSString stringWithFormat:@"%@ is not a file.", uri];

		OakDocument* document = [OakDocumentController.sharedInstance documentWithPath:url.path];
		NSData* data = document.isLoaded ? [document.content dataUsingEncoding:NSUTF8StringEncoding] : [NSData dataWithContentsOfFile:url.path];
		if(!data)
			return [NSString stringWithFormat:@"Unable to read %@.", url.path.lastPathComponent];

		std::vector<size_t> lineStarts = { 0 };
		char const* bytes = (char const*)data.bytes;
		for(size_t i = 0; i < data.length; ++i)
		{
			if(bytes[i] == '\n')
				lineStarts.push_back(i + 1);
		}

		// A position (line, UTF-16 offset) as a byte offset.
		auto offset = [&](NSDictionary* position) -> size_t {
			size_t line = [position[@"line"] unsignedIntegerValue];
			if(line >= lineStarts.size())
				return data.length;
			size_t start = lineStarts[line], end = line + 1 < lineStarts.size() ? lineStarts[line + 1] - 1 : data.length;
			NSString* text = [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding] ?: @"";
			NSUInteger character = MIN([position[@"character"] unsignedIntegerValue], text.length);
			return start + [[text substringToIndex:character] lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
		};

		// Only the lines that change are replaced.
		std::multimap<std::pair<size_t, size_t>, std::string> replacements;
		for(NSDictionary* textEdit in editsByURI[uri])
		{
			if(![textEdit isKindOfClass:[NSDictionary class]] || ![textEdit[@"newText"] isKindOfClass:[NSString class]])
				return @"The edit is not valid.";
			size_t const from = offset(textEdit[@"range"][@"start"]), to = offset(textEdit[@"range"][@"end"]);
			if(to < from)
				return @"The edit is not valid.";
			for(auto const& [range, text] : LineReplacements(std::string(bytes + from, bytes + to), to_s((NSString*)textEdit[@"newText"])))
				replacements.emplace(std::make_pair(from + range.first, from + range.second), text);
		}
		if(replacements.empty())
			continue;

		boost::crc_32_type checksum;
		checksum.process_bytes(data.bytes, data.length);
		changes.emplace_back(document, replacements, checksum.checksum());
	}

	for(auto& [document, replacements, checksum] : changes)
	{
		if(document.isLoaded)
		{
			[document performReplacements:replacements checksum:checksum];
		}
		else if([document performReplacements:replacements checksum:checksum])
		{
			OakDocument* saved = document;
			[saved saveModalForWindow:nil completionHandler:^(OakDocumentIOResult result, NSString* errorMessage, oak::uuid_t const& filterUUID){
				if(!saved.isLoaded) // Still not open
					saved.content = nil;
			}];
		}
		else
		{
			return [NSString stringWithFormat:@"%@ changed on disk.", document.path.lastPathComponent];
		}
	}
	return nil;
}
@end
