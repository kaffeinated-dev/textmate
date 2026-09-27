#import "LSPServer.h"
#import <io/pipe.h>
#import <ns/ns.h>
#import <oak/datatypes.h>

static NSTimeInterval const kShutDownTimeout = 3;

os_log_t LSPLog ()
{
	static os_log_t log = os_log_create("com.macromates.TextMate", "LanguageServer");
	return log;
}

NSString* LSPURIForPath (NSString* path)
{
	return [NSURL fileURLWithPath:path isDirectory:NO].absoluteString;
}

@interface LSPServer ()
{
	std::map<std::string, std::string> _environment;
	pid_t _processIdentifier;
	int _input; // The server’s standard input
	dispatch_queue_t _inputQueue;
	NSMutableData* _output; // Received from the server and not yet handled
	NSInteger _nextRequestIdentifier;
	NSMutableDictionary<NSNumber*, void(^)(id, NSDictionary*)>* _responseHandlers;
	NSMutableArray<NSDictionary*>* _pendingMessages; // Sent once initialized
	BOOL _initialized;
	BOOL _shuttingDown;
}
@end

@implementation LSPServer
- (instancetype)initWithCommand:(NSString*)command rootURL:(NSURL*)rootURL environment:(std::map<std::string, std::string> const&)environment
{
	if(self = [super init])
	{
		_command          = command;
		_rootURL          = rootURL;
		_environment      = environment;
		_input            = -1;
		_inputQueue       = dispatch_queue_create("org.textmate.language-server.input", DISPATCH_QUEUE_SERIAL);
		_output           = [NSMutableData data];
		_responseHandlers = [NSMutableDictionary dictionary];
		_pendingMessages  = [NSMutableArray array];
	}
	return self;
}

- (BOOL)isRunning
{
	return _processIdentifier != 0;
}

// ===========
// = Process =
// ===========

// The shell runs the command in the root folder, in a process group of its
// own, so that stopping the server stops the processes it started.
- (BOOL)start
{
	int childInput, input, output, childOutput, errors, childErrors;
	std::tie(childInput, input)   = io::create_pipe();
	std::tie(output, childOutput) = io::create_pipe();
	std::tie(errors, childErrors) = io::create_pipe();

	std::string const root    = to_s(_rootURL.path);
	std::string const command = to_s(_command);
	char const* argv[] = { "/bin/sh", "-c", "cd \"$1\" && eval \"$2\"", "sh", root.c_str(), command.c_str(), nullptr };

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, childInput, STDIN_FILENO);
	posix_spawn_file_actions_adddup2(&actions, childOutput, STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&actions, childErrors, STDERR_FILENO);

	sigset_t signals;
	sigfillset(&signals);

	posix_spawnattr_t attributes;
	posix_spawnattr_init(&attributes);
	posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF|POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETPGROUP);
	posix_spawnattr_setsigdefault(&attributes, &signals);
	posix_spawnattr_setpgroup(&attributes, 0);

	pid_t pid = 0;
	int rc = posix_spawn(&pid, argv[0], &actions, &attributes, (char* const*)argv, oak::c_array(_environment));

	posix_spawnattr_destroy(&attributes);
	posix_spawn_file_actions_destroy(&actions);
	close(childInput);
	close(childOutput);
	close(childErrors);

	if(rc != 0)
	{
		os_log_error(LSPLog(), "Unable to start %{public}@: %{public}s", _command, strerror(rc));
		close(input);
		close(output);
		close(errors);
		return NO;
	}

	os_log(LSPLog(), "Started %{public}@ (%d) in %{public}@", _command, pid, _rootURL.path);

	_processIdentifier = pid;
	_input = input;
	fcntl(input, F_SETNOSIGPIPE, 1);

	__weak LSPServer* weakSelf = self;
	[self readFileDescriptor:output queue:dispatch_get_main_queue() handler:^(NSData* data){
		[weakSelf receiveData:data];
	}];

	NSString* name = _command.lastPathComponent;
	[self readFileDescriptor:errors queue:dispatch_get_global_queue(QOS_CLASS_UTILITY, 0) handler:^(NSData* data){
		NSString* text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
		os_log_info(LSPLog(), "%{public}@: %{public}@", name, [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
	}];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		int status = 0;
		while(waitpid(pid, &status, 0) == -1 && errno == EINTR)
			;
		dispatch_async(dispatch_get_main_queue(), ^{
			[weakSelf processDidExit:pid status:status];
		});
	});

	[self sendInitialize];
	return YES;
}

- (void)readFileDescriptor:(int)fd queue:(dispatch_queue_t)queue handler:(void(^)(NSData*))handler
{
	fcntl(fd, F_SETFL, O_NONBLOCK);
	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, queue);
	dispatch_source_set_event_handler(source, ^{
		char buf[16384];
		ssize_t len = read(fd, buf, sizeof(buf));
		if(len > 0)
			handler([NSData dataWithBytes:buf length:len]);
		else if(len == 0 || (errno != EAGAIN && errno != EINTR))
			dispatch_source_cancel(source);
	});
	dispatch_source_set_cancel_handler(source, ^{
		close(fd);
	});
	dispatch_resume(source);
}

- (void)processDidExit:(pid_t)pid status:(int)status
{
	if(_processIdentifier != pid)
		return;

	os_log(LSPLog(), "%{public}@ (%d) exited with status %d", _command, pid, WIFEXITED(status) ? WEXITSTATUS(status) : -1);
	killpg(pid, SIGTERM); // Anything it started and left running
	_processIdentifier = 0;
	[self closeInput];

	NSDictionary* error = @{ @"code": @(-32099), @"message": @"The language server exited" };
	for(void(^handler)(id, NSDictionary*) in _responseHandlers.allValues)
		handler(nil, error);
	[_responseHandlers removeAllObjects];
	[_pendingMessages removeAllObjects];

	if(_terminationHandler)
		_terminationHandler(WIFEXITED(status) ? WEXITSTATUS(status) : -1);
}

- (void)closeInput
{
	int fd = _input;
	_input = -1;
	if(fd != -1)
		dispatch_async(_inputQueue, ^{ close(fd); });
}

// ============
// = Messages =
// ============

- (void)writeMessage:(NSDictionary*)message
{
	if(_input == -1)
		return;

	NSMutableDictionary* dictionary = [message mutableCopy];
	dictionary[@"jsonrpc"] = @"2.0";

	NSError* error;
	NSData* body = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
	if(!body)
		return (void)os_log_error(LSPLog(), "Unable to encode %{public}@: %{public}@", message[@"method"], error.localizedDescription);

	NSMutableData* data = [[[NSString stringWithFormat:@"Content-Length: %lu\r\n\r\n", body.length] dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
	[data appendData:body];

	int fd = _input;
	dispatch_async(_inputQueue, ^{
		char const* bytes = (char const*)data.bytes;
		size_t remaining = data.length;
		while(remaining)
		{
			ssize_t len = write(fd, bytes, remaining);
			if(len == -1)
			{
				if(errno == EINTR)
					continue;
				break;
			}
			bytes += len;
			remaining -= len;
		}
	});
}

- (void)sendMessage:(NSDictionary*)message
{
	if(_initialized)
			[self writeMessage:message];
	else	[_pendingMessages addObject:message];
}

- (void)sendNotification:(NSString*)method params:(id)params
{
	[self sendMessage:params ? @{ @"method": method, @"params": params } : @{ @"method": method }];
}

- (NSDictionary*)request:(NSString*)method params:(id)params handler:(void(^)(id result, NSDictionary* error))handler
{
	NSNumber* identifier = @(++_nextRequestIdentifier);
	if(handler)
		_responseHandlers[identifier] = handler;
	return params ? @{ @"id": identifier, @"method": method, @"params": params } : @{ @"id": identifier, @"method": method };
}

- (void)sendRequest:(NSString*)method params:(id)params handler:(void(^)(id result, NSDictionary* error))handler
{
	[self sendMessage:[self request:method params:params handler:handler]];
}

- (void)sendInitialize
{
	NSString* rootURI = LSPURIForPath(_rootURL.path);
	NSDictionary* params = @{
		@"processId":        @(getpid()),
		@"clientInfo":       @{ @"name": @"TextMate", @"version": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"" },
		@"rootUri":          rootURI,
		@"rootPath":         _rootURL.path,
		@"workspaceFolders": @[ @{ @"uri": rootURI, @"name": _rootURL.lastPathComponent } ],
		@"capabilities": @{
			@"workspace": @{
				@"workspaceFolders": @YES,
				@"configuration":    @YES,
			},
			@"textDocument": @{
				@"synchronization":    @{ @"didSave": @YES },
				@"publishDiagnostics": @{ @"relatedInformation": @NO },
			},
		},
	};

	__weak LSPServer* weakSelf = self;
	[self writeMessage:[self request:@"initialize" params:params handler:^(id result, NSDictionary* error){
		[weakSelf didInitialize:result error:error];
	}]];
}

- (void)didInitialize:(id)result error:(NSDictionary*)error
{
	if(error || ![result isKindOfClass:[NSDictionary class]])
	{
		os_log_error(LSPLog(), "%{public}@ did not initialize: %{public}@", _command, error[@"message"]);
		return [self shutDown];
	}

	_capabilities = [result[@"capabilities"] isKindOfClass:[NSDictionary class]] ? result[@"capabilities"] : @{ };
	_initialized = YES;

	[self writeMessage:@{ @"method": @"initialized", @"params": @{ } }];
	for(NSDictionary* message in _pendingMessages)
		[self writeMessage:message];
	[_pendingMessages removeAllObjects];
}

// =============
// = Receiving =
// =============

- (void)receiveData:(NSData*)data
{
	[_output appendData:data];

	static NSData* const separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
	while(true)
	{
		NSRange headerEnd = [_output rangeOfData:separator options:0 range:NSMakeRange(0, _output.length)];
		if(headerEnd.location == NSNotFound)
			return;

		NSInteger contentLength = -1;
		NSString* header = [[NSString alloc] initWithData:[_output subdataWithRange:NSMakeRange(0, headerEnd.location)] encoding:NSASCIIStringEncoding];
		for(NSString* line in [header componentsSeparatedByString:@"\r\n"])
		{
			if([line.lowercaseString hasPrefix:@"content-length:"])
				contentLength = [[line substringFromIndex:15] integerValue];
		}

		if(contentLength < 0)
		{
			os_log_error(LSPLog(), "%{public}@ sent a message without Content-Length: %{public}@", _command, header);
			[_output setLength:0];
			return;
		}

		NSUInteger start = NSMaxRange(headerEnd);
		if(_output.length < start + contentLength)
			return;

		NSData* body = [_output subdataWithRange:NSMakeRange(start, contentLength)];
		[_output replaceBytesInRange:NSMakeRange(0, start + contentLength) withBytes:nullptr length:0];

		id message = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
		if([message isKindOfClass:[NSDictionary class]])
			[self handleMessage:message];
	}
}

- (void)handleMessage:(NSDictionary*)message
{
	id identifier = message[@"id"];
	NSString* method = message[@"method"];

	if(method && identifier)
	{
		[self handleRequest:method params:message[@"params"] identifier:identifier];
	}
	else if(method)
	{
		NSDictionary* params = message[@"params"];
		if([method isEqualToString:@"window/logMessage"] || [method isEqualToString:@"window/showMessage"])
		{
			if([params[@"type"] intValue] == 1)
					os_log_error(LSPLog(), "%{public}@: %{public}@", _command.lastPathComponent, params[@"message"]);
			else	os_log_info(LSPLog(), "%{public}@: %{public}@", _command.lastPathComponent, params[@"message"]);
		}
		else if(_notificationHandler)
		{
			_notificationHandler(method, params);
		}
	}
	else if([identifier isKindOfClass:[NSNumber class]])
	{
		if(void(^handler)(id, NSDictionary*) = _responseHandlers[identifier])
		{
			[_responseHandlers removeObjectForKey:identifier];
			id error = message[@"error"];
			handler(message[@"result"], [error isKindOfClass:[NSDictionary class]] ? error : nil);
		}
	}
}

// Requests from the server, answered as a client without these features does.
- (void)handleRequest:(NSString*)method params:(id)params identifier:(id)identifier
{
	id result = NSNull.null;
	NSDictionary* error;

	if([method isEqualToString:@"workspace/configuration"])
	{
		NSMutableArray* configuration = [NSMutableArray array];
		for(NSUInteger i = 0; i < [params[@"items"] count]; ++i)
			[configuration addObject:NSNull.null];
		result = configuration;
	}
	else if([method isEqualToString:@"workspace/workspaceFolders"])
	{
		result = @[ @{ @"uri": LSPURIForPath(_rootURL.path), @"name": _rootURL.lastPathComponent } ];
	}
	else if([method isEqualToString:@"workspace/applyEdit"])
	{
		result = @{ @"applied": @NO };
	}
	else if(![@[ @"client/registerCapability", @"client/unregisterCapability", @"window/workDoneProgress/create", @"window/showMessageRequest" ] containsObject:method])
	{
		error = @{ @"code": @(-32601), @"message": [NSString stringWithFormat:@"TextMate does not support %@", method] };
	}

	[self writeMessage:error ? @{ @"id": identifier, @"error": error } : @{ @"id": identifier, @"result": result }];
}

// ============
// = Shutdown =
// ============

- (void)shutDown
{
	if(!self.isRunning || _shuttingDown)
		return;
	_shuttingDown = YES;

	__weak LSPServer* weakSelf = self;
	void(^sendExit)() = ^{
		[weakSelf writeMessage:@{ @"method": @"exit" }];
		[weakSelf closeInput];
	};

	if(_initialized)
			[self writeMessage:[self request:@"shutdown" params:nil handler:^(id, NSDictionary*){ sendExit(); }]];
	else	sendExit();

	pid_t pid = _processIdentifier;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kShutDownTimeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		killpg(pid, SIGTERM);
	});
}

- (void)shutDownAndWait
{
	if(!self.isRunning)
		return;

	pid_t pid = _processIdentifier;
	if(_initialized && !_shuttingDown)
		[self writeMessage:[self request:@"shutdown" params:nil handler:nil]];
	[self writeMessage:@{ @"method": @"exit" }];
	[self closeInput];
	dispatch_sync(_inputQueue, ^{ });

	for(size_t i = 0; i < 20 && kill(pid, 0) == 0; ++i)
		usleep(50000);
	killpg(pid, SIGTERM);
}
@end
