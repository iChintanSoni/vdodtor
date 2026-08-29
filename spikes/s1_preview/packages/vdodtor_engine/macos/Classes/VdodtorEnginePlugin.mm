// VdodtorEnginePlugin.mm — bridges the native engine's output to a Flutter
// external texture. Texture registration is the only thing that needs the
// plugin registrar, so it is the only thing on the method channel; all
// transport control goes over FFI directly to vd_engine_*.

#import "VdodtorEnginePlugin.h"
#import <CoreVideo/CoreVideo.h>
#include "vd_engine.h"

// ------------------------------------------------------------------ texture

@interface VdTexture : NSObject <FlutterTexture>
@property(nonatomic, assign) VdEngine *engine;
@end

@implementation VdTexture
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
  // +1 retained; Flutter releases it after upload.
  return (CVPixelBufferRef)vd_engine_copy_output(self.engine);
}
@end

// Context handed to the engine's frame callback (fires on the Metal
// completion handler thread; textureFrameAvailable: is thread-safe).
typedef struct {
  __unsafe_unretained NSObject<FlutterTextureRegistry> *registry;
  int64_t textureId;
} VdCallbackContext;

static void vd_on_frame(void *ctx) {
  VdCallbackContext *c = (VdCallbackContext *)ctx;
  [c->registry textureFrameAvailable:c->textureId];
}

// ------------------------------------------------------------------ plugin

@implementation VdodtorEnginePlugin {
  NSObject<FlutterTextureRegistry> *_textures;
  NSMutableDictionary<NSNumber *, VdTexture *> *_live;
  NSMutableDictionary<NSNumber *, NSValue *> *_contexts;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"vdodtor_engine"
                                  binaryMessenger:registrar.messenger];
  VdodtorEnginePlugin *instance = [[VdodtorEnginePlugin alloc] initWithRegistrar:registrar];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  if (self) {
    _textures = registrar.textures;
    _live = [NSMutableDictionary dictionary];
    _contexts = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([call.method isEqualToString:@"registerTexture"]) {
    int64_t ptr = [call.arguments[@"engine"] longLongValue];
    VdEngine *engine = (VdEngine *)ptr;
    if (!engine) {
      result([FlutterError errorWithCode:@"null_engine" message:@"engine pointer was null" details:nil]);
      return;
    }

    VdTexture *tex = [[VdTexture alloc] init];
    tex.engine = engine;
    int64_t textureId = [_textures registerTexture:tex];

    VdCallbackContext *ctx = (VdCallbackContext *)calloc(1, sizeof(VdCallbackContext));
    ctx->registry = _textures;
    ctx->textureId = textureId;
    vd_engine_set_frame_callback(engine, vd_on_frame, ctx);

    _live[@(textureId)] = tex;
    _contexts[@(textureId)] = [NSValue valueWithPointer:ctx];
    result(@(textureId));
    return;
  }

  if ([call.method isEqualToString:@"unregisterTexture"]) {
    NSNumber *tid = call.arguments[@"textureId"];
    VdTexture *tex = _live[tid];
    if (tex) {
      vd_engine_set_frame_callback(tex.engine, NULL, NULL);
      [_textures unregisterTexture:tid.longLongValue];
      [_live removeObjectForKey:tid];
      NSValue *v = _contexts[tid];
      if (v) {
        free([v pointerValue]);
        [_contexts removeObjectForKey:tid];
      }
    }
    result(nil);
    return;
  }

  result(FlutterMethodNotImplemented);
}

@end
