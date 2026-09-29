// Watches the root folder of a language server for the files it registers
// for (workspace/didChangeWatchedFiles), so that it hears about changes made
// by TextMate and by other programs, such as git or a generator.
//
// Changes are reported as the protocol’s file events, to a handler called on
// the main thread.

@interface LSPFileWatcher : NSObject
- (instancetype)initWithRootPath:(NSString*)rootPath handler:(void(^)(NSArray<NSDictionary*>* changes))handler;

// Watchers (FileSystemWatcher) of a registration, and its removal.
- (void)addWatchers:(NSArray*)watchers identifier:(NSString*)identifier;
- (void)removeWatchersWithIdentifier:(NSString*)identifier;

- (void)stop;
@end
