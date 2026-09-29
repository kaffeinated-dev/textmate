// Connects documents to the language servers that bundles set up, with a
// preference whose languageServer setting applies to the document’s scope:
//
//     languageServer = {
//       command    = '"$TM_BUNDLE_SUPPORT/bin/language-server"';
//       languageId = 'elixir';
//       rootFiles  = ( 'mix.exs' );
//       preferOuterRoot = :true;
//     };
//
// The server runs in the closest folder of the document with one of the root
// files (or, with preferOuterRoot, in the next one up, if there is one, such
// as the project of a dependency or the umbrella of an application), with the
// environment of bundle commands. It is kept up to date with the documents
// open in that folder, and its diagnostics (sent by it, or asked for once
// typing pauses) are shown as marks in the gutter. It is told about changes
// to the files it registers for, also those made by other programs.
//
// Setting TM_DISABLE_LANGUAGE_SERVER (in Preferences → Variables or a
// .tm_properties file) turns this off. Servers stop when TextMate quits.

#import <text/types.h>

@class OakDocument;

@interface LSPClient : NSObject
+ (instancetype)sharedInstance;

// Sends a request to the language server of a document. A textDocument/
// request gets the document (as textDocument) and, if given, a position (as
// TextMate has it: a zero-based line and byte offset) converted for the
// server; a code action request gets the line as range (unless it has one),
// and the diagnostics of its lines as context. Other requests (such as
// workspace/symbol or codeAction/resolve) are sent as they are, and
// workspace/applyEdit is applied by TextMate (replacing only the lines that
// change). Formatting requests fail as unknown methods (-32601) when the
// server does not format documents, and as -32002 while it is starting.
// Changes not yet sent to the server are sent first. Returns NO when the
// document has no language server; otherwise the handler is called on the
// main thread.
- (BOOL)sendRequest:(NSString*)method params:(NSDictionary*)params document:(OakDocument*)document position:(text::pos_t const&)position handler:(void(^)(id result, NSDictionary* error))handler;

// Whether the document has a language server (started, or starting), which
// OakTextView adds to its scope as attr.language-server.
- (BOOL)hasServerForDocument:(OakDocument*)document;

// The words the language server suggests for completing the word that starts
// at wordStart, with the caret at the position: the names of its completion
// items, or, for those that replace a range, the word from wordStart that the
// replacement makes (such as “Greeter” for “Sample::Greeter” replacing
// “Sample::Gre”), in the server’s order. Waits at most the timeout for the
// server, and returns nil without a server.
- (NSArray<NSString*>*)completionsForDocument:(OakDocument*)document wordStart:(text::pos_t const&)wordStart position:(text::pos_t const&)position timeout:(NSTimeInterval)timeout;
@end
