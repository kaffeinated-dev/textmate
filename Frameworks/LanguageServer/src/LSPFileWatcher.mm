#import "LSPFileWatcher.h"
#import "LSPServer.h"
#import <ns/ns.h>
#import <regexp/glob.h>

static CFTimeInterval const kLatency = 0.5; // Changes are reported this long after the first, together

// File change types and watch kinds of the protocol.
enum { kFileCreated = 1, kFileChanged = 2, kFileDeleted = 3 };
enum { kWatchCreate = 1, kWatchChange = 2, kWatchDelete = 4 };

namespace
{
	struct watcher_t
	{
		std::string base; // The pattern matches paths relative to this folder
		path::glob_t glob;
		int kind;
	};
}

@interface LSPFileWatcher ()
{
	NSString* _rootPath;
	NSString* _realRootPath; // As FSEvents reports paths
	void(^_handler)(NSArray<NSDictionary*>*);
	std::map<std::string, std::vector<watcher_t>> _watchers; // By registration
	FSEventStreamRef _stream;
}
- (void)didChangePaths:(NSArray<NSString*>*)paths flags:(FSEventStreamEventFlags const*)flags;
@end

static void EventStreamCallback (ConstFSEventStreamRef stream, void* info, size_t count, void* paths, FSEventStreamEventFlags const flags[], FSEventStreamEventId const ids[])
{
	[(__bridge LSPFileWatcher*)info didChangePaths:(__bridge NSArray*)paths flags:flags];
}

@implementation LSPFileWatcher
- (instancetype)initWithRootPath:(NSString*)rootPath handler:(void(^)(NSArray<NSDictionary*>*))handler
{
	if(self = [super init])
	{
		char buf[PATH_MAX];
		_rootPath     = rootPath;
		_realRootPath = realpath(rootPath.fileSystemRepresentation, buf) ? @(buf) : rootPath;
		_handler      = handler;
	}
	return self;
}

- (void)dealloc
{
	[self stop];
}

- (void)addWatchers:(NSArray*)watchers identifier:(NSString*)identifier
{
	std::vector<watcher_t> res;
	for(NSDictionary* watcher in [watchers isKindOfClass:[NSArray class]] ? watchers : @[ ])
	{
		if(![watcher isKindOfClass:[NSDictionary class]])
			continue;

		NSString* base = _rootPath;
		id pattern = watcher[@"globPattern"];
		if([pattern isKindOfClass:[NSDictionary class]]) // A relative pattern
		{
			id baseURI = pattern[@"baseUri"];
			if([baseURI isKindOfClass:[NSDictionary class]]) // A workspace folder
				baseURI = baseURI[@"uri"];
			NSURL* url = [baseURI isKindOfClass:[NSString class]] ? [NSURL URLWithString:baseURI] : nil;
			base    = url.isFileURL ? url.path : nil;
			pattern = pattern[@"pattern"];
		}

		if(!base || ![pattern isKindOfClass:[NSString class]] || ![pattern length])
			continue;

		// The leading slash anchors a pattern to its base, and an absolute one
		// matches the whole path.
		std::string glob = to_s((NSString*)pattern), basePath = to_s(base);
		if(glob.front() == '/')
				basePath = "";
		else	glob = "/" + glob;

		int kind = [watcher[@"kind"] isKindOfClass:[NSNumber class]] ? [watcher[@"kind"] intValue] : kWatchCreate|kWatchChange|kWatchDelete;
		res.push_back({ basePath, path::glob_t(glob, true), kind });
	}

	_watchers[to_s(identifier)] = res;
	[self start];
}

- (void)removeWatchersWithIdentifier:(NSString*)identifier
{
	_watchers.erase(to_s(identifier));
	if(_watchers.empty())
		[self stopStream];
}

- (void)stop
{
	_watchers.clear();
	[self stopStream];
}

// ==========
// = Stream =
// ==========

- (void)start
{
	if(_stream)
		return;

	FSEventStreamContext context = { 0, (__bridge void*)self, nullptr, nullptr, nullptr };
	_stream = FSEventStreamCreate(kCFAllocatorDefault, &EventStreamCallback, &context, (__bridge CFArrayRef)@[ _realRootPath ], kFSEventStreamEventIdSinceNow, kLatency, kFSEventStreamCreateFlagFileEvents|kFSEventStreamCreateFlagUseCFTypes);
	if(!_stream)
		return (void)os_log_error(LSPLog(), "Unable to watch %{public}@", _rootPath);

	FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
	FSEventStreamStart(_stream);
}

- (void)stopStream
{
	if(!_stream)
		return;

	FSEventStreamStop(_stream);
	FSEventStreamInvalidate(_stream);
	FSEventStreamRelease(_stream);
	_stream = nullptr;
}

// ==========
// = Events =
// ==========

- (void)didChangePaths:(NSArray<NSString*>*)paths flags:(FSEventStreamEventFlags const*)flags
{
	FSEventStreamEventFlags const kItemFlags   = kFSEventStreamEventFlagItemIsFile|kFSEventStreamEventFlagItemIsSymlink;
	FSEventStreamEventFlags const kChangeFlags = kFSEventStreamEventFlagItemCreated|kFSEventStreamEventFlagItemRemoved|kFSEventStreamEventFlagItemRenamed|kFSEventStreamEventFlagItemModified;

	NSMutableArray<NSString*>* changedPaths = [NSMutableArray array];
	NSMutableDictionary<NSString*, NSNumber*>* types = [NSMutableDictionary dictionary];
	for(NSUInteger i = 0; i < paths.count; ++i)
	{
		if(!(flags[i] & kItemFlags) || !(flags[i] & kChangeFlags))
			continue;

		NSString* path = paths[i];
		if([path hasPrefix:_realRootPath])
			path = [_rootPath stringByAppendingString:[path substringFromIndex:_realRootPath.length]];
		if([path containsString:@"/.git/"])
			continue;

		// Whether a file is new cannot be told from the flags, which FSEvents
		// coalesces, so a file that exists is changed. ruby-lsp, for one,
		// indexes a changed file that it does not know, but would index a
		// created file that it does know twice.
		struct stat sbuf;
		BOOL exists = lstat(path.fileSystemRepresentation, &sbuf) == 0;
		if(![self isWatchingPath:path kind:exists ? kWatchCreate|kWatchChange : kWatchDelete])
			continue;

		if(!types[path])
			[changedPaths addObject:path];
		types[path] = @(exists ? kFileChanged : kFileDeleted);
	}

	if(!changedPaths.count)
		return;

	NSMutableArray* changes = [NSMutableArray array];
	for(NSString* path in changedPaths)
		[changes addObject:@{ @"uri": LSPURIForPath(path), @"type": types[path] }];
	_handler(changes);
}

- (BOOL)isWatchingPath:(NSString*)path kind:(int)kind
{
	std::string const str = to_s(path);
	for(auto const& pair : _watchers)
	{
		for(auto const& watcher : pair.second)
		{
			std::string const& base = watcher.base;
			if(!(watcher.kind & kind) || str.compare(0, base.size(), base) != 0 || (str.size() > base.size() && str[base.size()] != '/'))
				continue;
			if(watcher.glob.does_match(str.substr(base.size())))
				return YES;
		}
	}
	return NO;
}
@end
