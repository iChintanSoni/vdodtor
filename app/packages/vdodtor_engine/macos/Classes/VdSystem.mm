#import "VdSystem.h"

#import <AppKit/AppKit.h>

@implementation VdSystem {
  FlutterMethodChannel *_channel;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"vdodtor/system"
                                  binaryMessenger:registrar.messenger];
  VdSystem *instance = [[VdSystem alloc] initWithChannel:channel];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithChannel:(FlutterMethodChannel *)channel {
  self = [super init];
  if (self) _channel = channel;
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  if (![call.method isEqualToString:@"openUrl"]) {
    result(FlutterMethodNotImplemented);
    return;
  }

  NSDictionary *arguments =
      [call.arguments isKindOfClass:[NSDictionary class]] ? call.arguments : nil;
  NSString *string = arguments[@"url"];
  NSURL *url = [string isKindOfClass:[NSString class]]
                   ? [NSURL URLWithString:string]
                   : nil;

  // http and https only. Everything this opens is a page we wrote the address
  // of, so the check costs nothing — and it means that if a URL ever does come
  // from somewhere less trustworthy than a constant, this cannot be talked
  // into handing `file:` or a custom scheme to Launch Services.
  BOOL web = url != nil && ([url.scheme isEqualToString:@"https"] ||
                            [url.scheme isEqualToString:@"http"]);
  if (!web) {
    result(@(NO));
    return;
  }

  result(@([[NSWorkspace sharedWorkspace] openURL:url]));
}

@end
