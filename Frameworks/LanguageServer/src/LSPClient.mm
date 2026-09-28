#import "LSPClient.h"
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

static NSTimeInterval const kChangeDelay       = 0.3; // Changes are sent once typing pauses for this long
static NSTimeInterval const kIdleShutDownDelay = 300; // A server without open documents is stopped after this long
static NSTimeInterval const kRestartDelay      = 60;  // A server that exited is not started again sooner

// Marks for diagnostics: lsp/error, lsp/warning, and lsp/note.
static NSString* const kMarkTypePrefix = @"lsp/";

// What a server knows about a document.
@interface LSPDocument : NSObject
@property (nonatomic) LSPServer* server;
@property (nonatomic) NSString* serverKey;
@property (nonatomic) NSString* uri;
@property (nonatomic) NSInteger version;
@property (nonatomic) NSTimer* changeTimer;
@end

@implementation LSPDocument
@end

@interface LSPClient ()
{
	NSMutableDictionary<NSString*, LSPServer*>* _servers; // By command and root folder
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

	[state.changeTimer invalidate];
	state.changeTimer = [NSTimer scheduledTimerWithTimeInterval:kChangeDelay target:self selector:@selector(changeTimerDidFire:) userInfo:document repeats:NO];
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

	if(state.changeTimer)
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
	_documents[document.identifier] = state;

	[server sendNotification:@"textDocument/didOpen" params:@{
		@"textDocument": @{
			@"uri":        state.uri,
			@"languageId": languageId,
			@"version":    @(state.version),
			@"text":       document.content ?: @"",
		}
	}];
}

- (void)sendChangesForDocument:(OakDocument*)document
{
	LSPDocument* state = _documents[document.identifier];
	[state.changeTimer invalidate];
	state.changeTimer = nil;
	if(!state || !state.server.isRunning)
		return;

	state.version += 1;
	[state.server sendNotification:@"textDocument/didChange" params:@{
		@"textDocument":   @{ @"uri": state.uri, @"version": @(state.version) },
		@"contentChanges": @[ @{ @"text": document.content ?: @"" } ],
	}];
}

- (void)closeDocument:(OakDocument*)document
{
	[_documentsWithoutServer removeObject:document.identifier];

	LSPDocument* state = _documents[document.identifier];
	if(!state)
		return;

	[state.changeTimer invalidate];
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

	if(state.changeTimer)
		[self sendChangesForDocument:document];

	// Workspace requests (such as workspace/symbol) go to the document’s server, as they are.
	NSMutableDictionary* request = [params mutableCopy] ?: [NSMutableDictionary dictionary];
	if([method hasPrefix:@"workspace/"])
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

- (NSArray<NSString*>*)completionsForDocument:(OakDocument*)document position:(text::pos_t const&)position timeout:(NSTimeInterval)timeout
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

	// The name of an item such as “map(enumerable, fun)”, completed as a word.
	NSCharacterSet* nameEnd = [NSCharacterSet characterSetWithCharactersInString:@"( "];
	NSMutableOrderedSet* words = [NSMutableOrderedSet orderedSet];
	for(NSDictionary* item in sorted)
	{
		NSString* name = [item[@"filterText"] isKindOfClass:[NSString class]] ? item[@"filterText"] : item[@"label"];
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
			return [method isEqualToString:@"workspace/applyEdit"] && [params isKindOfClass:[NSDictionary class]] ? [weakSelf applyEditRequest:params] : nil;
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

	for(NSUUID* identifier in _documents.allKeys)
	{
		if(_documents[identifier].server == server)
		{
			[_documents[identifier].changeTimer invalidate];
			[_documents removeObjectForKey:identifier];
		}
	}
}

// ===============
// = Diagnostics =
// ===============

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

		std::multimap<std::pair<size_t, size_t>, std::string> replacements;
		for(NSDictionary* textEdit in editsByURI[uri])
		{
			if(![textEdit isKindOfClass:[NSDictionary class]] || ![textEdit[@"newText"] isKindOfClass:[NSString class]])
				return @"The edit is not valid.";
			replacements.emplace(std::make_pair(offset(textEdit[@"range"][@"start"]), offset(textEdit[@"range"][@"end"])), to_s((NSString*)textEdit[@"newText"]));
		}

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
