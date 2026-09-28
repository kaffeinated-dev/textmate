// A connection to a language server: a process that speaks the Language
// Server Protocol, JSON-RPC over its standard input and output.
//
// Positions sent and received use UTF-16 code units for characters, as the
// protocol does by default.

os_log_t LSPLog ();
NSString* LSPURIForPath (NSString* path);

@interface LSPServer : NSObject
- (instancetype)initWithCommand:(NSString*)command rootURL:(NSURL*)rootURL environment:(std::map<std::string, std::string> const&)environment;

@property (nonatomic, readonly) NSString* command;
@property (nonatomic, readonly) NSURL* rootURL;
@property (nonatomic, readonly, getter = isRunning) BOOL running;
@property (nonatomic, readonly) NSDictionary* capabilities; // Once initialized

// Called on the main thread with notifications from the server (except for
// log messages, which are logged), and once the process has exited.
@property (nonatomic, copy) void(^notificationHandler)(NSString* method, id params);
@property (nonatomic, copy) void(^terminationHandler)(int status);

// Called on the main thread with requests from the server that it doesn’t
// answer itself (such as workspace/applyEdit). Returns the result, or nil for
// an error.
@property (nonatomic, copy) id(^requestHandler)(NSString* method, id params);

// Starts the process, run by /bin/sh in the root folder, and initializes the
// server. Messages sent before the server is initialized are sent once it is.
- (BOOL)start;
- (void)sendNotification:(NSString*)method params:(id)params;
- (void)sendRequest:(NSString*)method params:(id)params handler:(void(^)(id result, NSDictionary* error))handler;

// Asks the server to shut down and exit, and stops its processes if it hasn't
// after a few seconds.
- (void)shutDown;
// Like shutDown, but waits at most a second for the server to exit, for when
// TextMate quits.
- (void)shutDownAndWait;
@end
