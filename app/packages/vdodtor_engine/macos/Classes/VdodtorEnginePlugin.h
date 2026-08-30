#import <FlutterMacOS/FlutterMacOS.h>

// Registers the preview texture.
//
// Almost all of the engine is reached over dart:ffi, which is direct and has
// no per-call overhead. This class exists for the one thing FFI cannot do:
// only a plugin registrar can mint a Flutter texture id, so texture
// registration goes over a method channel and everything else does not.
@interface VdodtorEnginePlugin : NSObject <FlutterPlugin>
@end
