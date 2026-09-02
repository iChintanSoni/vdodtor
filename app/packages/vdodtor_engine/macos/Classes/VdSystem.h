#import <FlutterMacOS/FlutterMacOS.h>

// The one thing the editor asks the rest of the machine to do: open a web
// address in the user's browser.
//
// It exists because the checkout does. An editor that sells a Pro tier has to
// be able to send somebody to the page that sells it, and a sandboxed app may
// not run `open` — NSWorkspace is the API the sandbox allows, and reaching it
// needs a few lines of Objective-C on this side of the channel.
//
// Deliberately not part of VdMediaAccess: that class is about getting at the
// user's files and holds security-scoped bookmarks, and a URL opener has
// nothing to do with either. Registered by VdodtorEnginePlugin, on the
// channel `vdodtor/system`.
@interface VdSystem : NSObject <FlutterPlugin>
@end
