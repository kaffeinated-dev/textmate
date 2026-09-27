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

- (void)clearDiagnosticsForKey:(NSString*)key
{
	for(NSString* path in _diagnosedPaths[key])
		[[OakDocumentController.sharedInstance documentWithPath:path] removeAllMarksOfType:kMarkTypePrefix];
	[_diagnosedPaths removeObjectForKey:key];
}
@end
