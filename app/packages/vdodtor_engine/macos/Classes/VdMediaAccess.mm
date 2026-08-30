#import "VdMediaAccess.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// A directory is accepted so a folder of footage can be dropped; what is
// inside it is the caller's problem, and it can list it because dropping a
// folder grants access to its contents.
static BOOL vd_is_importable(NSURL *url) {
  NSNumber *isDirectory = nil;
  if ([url getResourceValue:&isDirectory
                     forKey:NSURLIsDirectoryKey
                      error:nil] &&
      isDirectory.boolValue) {
    return YES;
  }

  UTType *type = nil;
  if (![url getResourceValue:&type forKey:NSURLContentTypeKey error:nil] ||
      type == nil) {
    return NO;
  }
  return [type conformsToType:UTTypeMovie] ||
         [type conformsToType:UTTypeAudiovisualContent] ||
         [type conformsToType:UTTypeAudio] ||
         [type conformsToType:UTTypeImage];
}

// A security-scoped bookmark, base64'd for the project file, or nil if one
// cannot be made. nil is survivable — the path still works for this run — so
// it is never an error, only a file the app will have to be given again.
static NSString *_Nullable vd_bookmark(NSURL *url) {
  NSError *error = nil;
  NSData *data =
      [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
    includingResourceValuesForKeys:nil
                     relativeToURL:nil
                             error:&error];
  if (data == nil) {
    NSLog(@"vdodtor: no bookmark for %@: %@", url.path, error);
    return nil;
  }
  return [data base64EncodedStringWithOptions:0];
}

static NSDictionary *vd_file_entry(NSURL *url) {
  NSString *bookmark = vd_bookmark(url);
  return @{@"path" : url.path, @"bookmark" : bookmark ?: [NSNull null]};
}

#pragma mark - drop target

@protocol VdDropDelegate <NSObject>
- (void)dropTargetDidEnterWithCount:(NSInteger)count;
- (void)dropTargetDidExit;
- (void)dropTargetDidDropURLs:(NSArray<NSURL *> *)urls at:(NSPoint)point;
@end

// A transparent view over the Flutter view that accepts file drags.
//
// It has to be a view — AppKit finds a drag destination by walking the view
// hierarchy — but it must not become one for anything else, so -hitTest:
// returns nil and every mouse event carries on to the Flutter view beneath as
// though this were not here. -isFlipped is YES so a converted drag location is
// already in Flutter's coordinates: origin top left, in points.
@interface VdDropView : NSView
@property(nonatomic, weak) id<VdDropDelegate> handler;
@end

@implementation VdDropView

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
  }
  return self;
}

- (BOOL)isFlipped { return YES; }

- (NSView *)hitTest:(NSPoint)point { return nil; }

- (NSArray<NSURL *> *)importableURLsFrom:(id<NSDraggingInfo>)sender {
  NSArray *urls = [sender.draggingPasteboard
      readObjectsForClasses:@[ [NSURL class] ]
                    options:@{NSPasteboardURLReadingFileURLsOnlyKey : @YES}];
  NSMutableArray<NSURL *> *keep = [NSMutableArray array];
  for (NSURL *url in urls) {
    if (vd_is_importable(url)) [keep addObject:url];
  }
  return keep;
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  NSArray<NSURL *> *urls = [self importableURLsFrom:sender];
  if (urls.count == 0) return NSDragOperationNone;
  [self.handler dropTargetDidEnterWithCount:(NSInteger)urls.count];
  return NSDragOperationCopy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  return [self importableURLsFrom:sender].count > 0 ? NSDragOperationCopy
                                                    : NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
  [self.handler dropTargetDidExit];
}

- (void)draggingEnded:(id<NSDraggingInfo>)sender {
  [self.handler dropTargetDidExit];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  NSArray<NSURL *> *urls = [self importableURLsFrom:sender];
  if (urls.count == 0) return NO;
  [self.handler
      dropTargetDidDropURLs:urls
                         at:[self convertPoint:sender.draggingLocation
                                      fromView:nil]];
  return YES;
}

@end

#pragma mark - plugin

@interface VdMediaAccess () <VdDropDelegate>
@end

@implementation VdMediaAccess {
  FlutterMethodChannel *_channel;
  __weak NSView *_view;
  // Bookmarked URLs currently being accessed, by path. Balanced so a project
  // that is closed and reopened does not leak a scope per open, and so the
  // stop can find the URL the start was called on — a different NSURL for the
  // same path will not do.
  NSMutableDictionary<NSString *, NSURL *> *_accessing;
  BOOL _panelOpen;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"vdodtor/media_access"
                                  binaryMessenger:registrar.messenger];
  VdMediaAccess *instance = [[VdMediaAccess alloc] initWithChannel:channel
                                                              view:registrar.view];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithChannel:(FlutterMethodChannel *)channel
                           view:(NSView *)view {
  self = [super init];
  if (self) {
    _channel = channel;
    _view = view;
    _accessing = [NSMutableDictionary dictionary];
    [self attachDropTargetTo:view];
  }
  return self;
}

- (void)attachDropTargetTo:(NSView *)view {
  if (view == nil) return;
  VdDropView *drop = [[VdDropView alloc] initWithFrame:view.bounds];
  drop.handler = self;
  drop.translatesAutoresizingMaskIntoConstraints = NO;
  [view addSubview:drop];
  // Constraints rather than an autoresizing mask: the Flutter view's bounds
  // are not necessarily right at plugin-registration time, and a drop target
  // that is the wrong size is one that silently ignores half the window.
  [NSLayoutConstraint activateConstraints:@[
    [drop.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
    [drop.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
    [drop.topAnchor constraintEqualToAnchor:view.topAnchor],
    [drop.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
  ]];
}

#pragma mark VdDropDelegate

- (void)dropTargetDidEnterWithCount:(NSInteger)count {
  [_channel invokeMethod:@"dragEntered" arguments:@{@"count" : @(count)}];
}

- (void)dropTargetDidExit {
  [_channel invokeMethod:@"dragExited" arguments:nil];
}

- (void)dropTargetDidDropURLs:(NSArray<NSURL *> *)urls at:(NSPoint)point {
  NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
  for (NSURL *url in urls) [files addObject:vd_file_entry(url)];
  [_channel invokeMethod:@"drop"
               arguments:@{
                 @"files" : files,
                 @"x" : @(point.x),
                 @"y" : @(point.y),
               }];
}

#pragma mark method channel

- (void)handleMethodCall:(FlutterMethodCall *)call
                  result:(FlutterResult)result {
  if ([call.method isEqualToString:@"pickFiles"]) {
    [self pickFiles:call result:result];
  } else if ([call.method isEqualToString:@"bookmark"]) {
    NSString *path = call.arguments[@"path"];
    if (![path isKindOfClass:[NSString class]] || path.length == 0) {
      result([FlutterError errorWithCode:@"bad-path"
                                 message:@"bookmark needs a path"
                                 details:nil]);
      return;
    }
    result(vd_bookmark([NSURL fileURLWithPath:path]));
  } else if ([call.method isEqualToString:@"resolveBookmark"]) {
    [self resolveBookmark:call result:result];
  } else if ([call.method isEqualToString:@"stopAccess"]) {
    NSString *path = call.arguments[@"path"];
    NSURL *url = path ? _accessing[path] : nil;
    if (url) {
      [url stopAccessingSecurityScopedResource];
      [_accessing removeObjectForKey:path];
    }
    result(nil);
  } else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)pickFiles:(FlutterMethodCall *)call result:(FlutterResult)result {
  if (_panelOpen) {
    // Two panels for one app is never what anyone meant, and the second one
    // would leave the first's completion handler waiting forever.
    result(@[]);
    return;
  }

  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.allowsMultipleSelection =
      [call.arguments[@"multiple"] boolValue] ||
      call.arguments[@"multiple"] == nil;
  panel.canChooseDirectories = NO;
  panel.canChooseFiles = YES;
  panel.message = @"Choose video, audio or images to import";
  panel.prompt = @"Import";
  panel.allowedContentTypes =
      @[ UTTypeMovie, UTTypeAudiovisualContent, UTTypeAudio, UTTypeImage ];

  _panelOpen = YES;
  __weak VdMediaAccess *weakSelf = self;
  void (^finish)(NSModalResponse) = ^(NSModalResponse response) {
    VdMediaAccess *strongSelf = weakSelf;
    if (strongSelf) strongSelf->_panelOpen = NO;
    if (response != NSModalResponseOK) {
      // Cancelling is not an error. An empty list is the honest answer and
      // saves every caller an "if cancelled" branch.
      result(@[]);
      return;
    }
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    for (NSURL *url in panel.URLs) [files addObject:vd_file_entry(url)];
    result(files);
  };

  // Never runModal: it spins its own run loop on the platform thread, and
  // everything Flutter needs to do — including drawing the window the panel is
  // attached to — happens on that thread.
  NSWindow *window = _view.window;
  if (window) {
    [panel beginSheetModalForWindow:window completionHandler:finish];
  } else {
    [panel beginWithCompletionHandler:finish];
  }
}

- (void)resolveBookmark:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSString *encoded = call.arguments[@"bookmark"];
  if (![encoded isKindOfClass:[NSString class]] || encoded.length == 0) {
    result(nil);
    return;
  }
  NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
  if (data == nil) {
    result(nil);
    return;
  }

  BOOL stale = NO;
  NSError *error = nil;
  NSURL *url = [NSURL
      URLByResolvingBookmarkData:data
                         options:NSURLBookmarkResolutionWithSecurityScope
                   relativeToURL:nil
             bookmarkDataIsStale:&stale
                           error:&error];
  if (url == nil) {
    NSLog(@"vdodtor: bookmark did not resolve: %@", error);
    result(nil);
    return;
  }

  // Starting access is what the bookmark is for. Not balanced here: it is
  // released by stopAccess when the project closes, because everything in
  // between — probing, decoding, thumbnailing — needs it open.
  const BOOL started = [url startAccessingSecurityScopedResource];
  if (started) {
    NSURL *existing = _accessing[url.path];
    if (existing) [existing stopAccessingSecurityScopedResource];
    _accessing[url.path] = url;
  }

  // A stale bookmark still resolves, and the fresh one is minted from the URL
  // it resolved to, so a file that moved is relinked rather than lost.
  NSString *refreshed = stale ? vd_bookmark(url) : nil;
  result(@{
    @"path" : url.path,
    @"stale" : @(stale),
    @"granted" : @(started),
    @"bookmark" : refreshed ?: [NSNull null],
  });
}

- (void)dealloc {
  for (NSURL *url in _accessing.allValues) {
    [url stopAccessingSecurityScopedResource];
  }
}

@end
