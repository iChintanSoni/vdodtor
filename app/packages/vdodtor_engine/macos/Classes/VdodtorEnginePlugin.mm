#import "VdodtorEnginePlugin.h"

#import <CoreVideo/CoreVideo.h>

#import "VdMediaAccess.h"

#include "vdodtor/vd_engine.h"

// One registered preview surface: a Flutter texture backed by whatever the
// engine last composited.
@interface VdEngineTexture : NSObject <FlutterTexture>
@property(nonatomic, assign) VdEngine *engine;
@property(nonatomic, assign) int64_t textureId;
@property(nonatomic, weak) NSObject<FlutterTextureRegistry> *registry;
@end

@implementation VdEngineTexture

// Called on Flutter's raster thread. vd_engine_copy_output hands back a
// retained buffer, which is exactly the contract Flutter wants: it releases
// what it is given.
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  if (self.engine == NULL) return NULL;
  return (CVPixelBufferRef)vd_engine_copy_output(self.engine);
}

@end

// Bridges the engine's frame callback to the texture registry. Called on the
// engine's render thread; textureFrameAvailable: is safe from any thread.
static void vd_on_frame(void *context) {
  VdEngineTexture *texture = (__bridge VdEngineTexture *)context;
  NSObject<FlutterTextureRegistry> *registry = texture.registry;
  if (registry) [registry textureFrameAvailable:texture.textureId];
}

@implementation VdodtorEnginePlugin {
  NSObject<FlutterTextureRegistry> *_registry;
  NSMutableDictionary<NSNumber *, VdEngineTexture *> *_textures;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"vdodtor/engine"
                                  binaryMessenger:registrar.messenger];
  VdodtorEnginePlugin *instance =
      [[VdodtorEnginePlugin alloc] initWithRegistrar:registrar];
  [registrar addMethodCallDelegate:instance channel:channel];

  // The generated registrant only knows about one plugin class per package,
  // so the file-access half registers from here rather than growing a second
  // entry in someone's build file.
  [VdMediaAccess registerWithRegistrar:registrar];
}

- (instancetype)initWithRegistrar:
    (NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  if (self) {
    _registry = registrar.textures;
    _textures = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  if ([call.method isEqualToString:@"registerTexture"]) {
    NSNumber *handle = call.arguments[@"engine"];
    if (![handle isKindOfClass:[NSNumber class]] ||
        handle.unsignedLongLongValue == 0) {
      result([FlutterError errorWithCode:@"bad-engine"
                                 message:@"registerTexture needs an engine "
                                         @"pointer from vd_engine_create"
                                 details:nil]);
      return;
    }

    VdEngineTexture *texture = [[VdEngineTexture alloc] init];
    texture.engine = (VdEngine *)(uintptr_t)handle.unsignedLongLongValue;
    texture.registry = _registry;
    texture.textureId = [_registry registerTexture:texture];
    _textures[@(texture.textureId)] = texture;

    // Registered before the callback is armed, so a frame can never arrive
    // for a texture id that does not exist yet.
    vd_engine_set_frame_callback(texture.engine, vd_on_frame,
                                 (__bridge void *)texture);
    result(@(texture.textureId));
    return;
  }

  if ([call.method isEqualToString:@"unregisterTexture"]) {
    NSNumber *textureId = call.arguments[@"textureId"];
    VdEngineTexture *texture = _textures[textureId];
    if (texture) {
      // Order matters, and this is the order: stop the engine calling us,
      // then stop Flutter calling the engine, and only then may the caller
      // destroy the engine.
      if (texture.engine) {
        vd_engine_set_frame_callback(texture.engine, NULL, NULL);
      }
      texture.engine = NULL;
      [_registry unregisterTexture:textureId.longLongValue];
      [_textures removeObjectForKey:textureId];
    }
    result(nil);
    return;
  }

  result(FlutterMethodNotImplemented);
}

@end
