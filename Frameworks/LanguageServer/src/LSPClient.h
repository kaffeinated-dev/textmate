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
// open in that folder, and its diagnostics are shown as marks in the gutter.
//
// Setting TM_DISABLE_LANGUAGE_SERVER (in Preferences → Variables or a
// .tm_properties file) turns this off. Servers stop when TextMate quits.

@interface LSPClient : NSObject
+ (instancetype)sharedInstance;
@end
