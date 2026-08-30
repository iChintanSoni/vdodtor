#import <FlutterMacOS/FlutterMacOS.h>

// Getting at files the app did not choose.
//
// Everything else the engine touches lives somewhere the sandbox already
// grants — the app's own bundle, its container, `~/Movies/vdodtor`. Imported
// media does not: the user's footage is theirs, and the only ways in are an
// open panel and a drop on the window. Both hand over access that lasts as
// long as the process, so both are followed immediately by minting a
// security-scoped bookmark, which is the only thing that survives a quit.
//
// This is the whole of that: the panel, the drop target, and the bookmarks.
// Registered by VdodtorEnginePlugin, on the channel `vdodtor/media_access`.
@interface VdMediaAccess : NSObject <FlutterPlugin>
@end
