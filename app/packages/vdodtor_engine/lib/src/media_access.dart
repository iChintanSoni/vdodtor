/// Getting at files the app did not choose: the open panel, drops on the
/// window, and the security-scoped bookmarks that make either survive a quit.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A file the user has granted access to, and the bookmark that will grant it
/// again next launch.
@immutable
class GrantedFile {
  const GrantedFile({required this.path, this.bookmark});

  final String path;

  /// Base64 security-scoped bookmark, or null when one could not be made —
  /// survivable, since the path works for as long as this process lives, but
  /// the file will have to be given to the app again next launch.
  final String? bookmark;

  @override
  bool operator ==(Object other) =>
      other is GrantedFile && other.path == path && other.bookmark == bookmark;

  @override
  int get hashCode => Object.hash(path, bookmark);

  @override
  String toString() =>
      'GrantedFile($path${bookmark == null ? ', unbookmarked' : ''})';
}

/// What a bookmark resolved to.
@immutable
class ResolvedFile {
  const ResolvedFile({
    required this.path,
    required this.granted,
    required this.stale,
    this.refreshedBookmark,
  });

  /// Where the file is *now* — not necessarily where it was when the bookmark
  /// was made, which is the whole point of having one.
  final String path;

  /// False if the bookmark resolved but the sandbox refused the scope. The
  /// path is still worth having; reading it is what will fail.
  final bool granted;

  /// The file moved, or the bookmark was made by an older build. Still valid,
  /// but [refreshedBookmark] should replace it.
  final bool stale;

  final String? refreshedBookmark;
}

/// Where a drop landed, and what was in it.
@immutable
class MediaDrop {
  const MediaDrop({required this.files, required this.position});

  final List<GrantedFile> files;

  /// Local coordinates of the pointer when the files were released, in
  /// logical pixels from the top left of the Flutter view. Unused in M1 —
  /// everything is appended — and the timeline's reason to exist in M2.
  final Offset position;
}

/// The platform side of import.
///
/// Static because there is one window and one sandbox; an instance per caller
/// would be an instance per *nothing*. Off macOS every call is a no-op that
/// answers "no access", so the app compiles and runs on a platform whose
/// engine is not written yet.
abstract final class MediaAccess {
  static const MethodChannel _channel = MethodChannel('vdodtor/media_access');

  static final StreamController<MediaDrop> _drops =
      StreamController<MediaDrop>.broadcast();
  static final ValueNotifier<bool> _dragOver = ValueNotifier<bool>(false);
  static bool _listening = false;

  /// Files dropped on the window. Broadcast: the editor listens while it is
  /// open, and nothing listens while the chooser is up.
  static Stream<MediaDrop> get drops {
    _startListening();
    return _drops.stream;
  }

  /// True while importable files are being dragged over the window. Drives the
  /// drop highlight; separate from [drops] because it changes far more often
  /// and drives a repaint rather than an edit.
  static ValueListenable<bool> get isDragOver {
    _startListening();
    return _dragOver;
  }

  static void _startListening() {
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler(_onPlatformCall);
  }

  static Future<void> _onPlatformCall(MethodCall call) async {
    switch (call.method) {
      case 'dragEntered':
        _dragOver.value = true;
      case 'dragExited':
        _dragOver.value = false;
      case 'drop':
        _dragOver.value = false;
        final args = (call.arguments as Map).cast<Object?, Object?>();
        _drops.add(MediaDrop(
          files: _filesFrom(args['files']),
          position: Offset(
            (args['x'] as num?)?.toDouble() ?? 0,
            (args['y'] as num?)?.toDouble() ?? 0,
          ),
        ));
    }
  }

  /// Opens the system file panel. Returns the chosen files, or an empty list
  /// if the user cancelled — cancelling is not a failure and does not deserve
  /// a branch in every caller.
  static Future<List<GrantedFile>> pickFiles({bool multiple = true}) async {
    final files = await _channel.invokeMethod<List<Object?>>(
        'pickFiles', {'multiple': multiple});
    return _filesFrom(files);
  }

  /// Mints a bookmark for a file the app can already reach. Null if it cannot.
  static Future<String?> bookmark(String path) =>
      _channel.invokeMethod<String>('bookmark', {'path': path});

  /// Resolves a bookmark and starts accessing what it points at, which lasts
  /// until [stopAccess]. Null if the bookmark is unusable — a file deleted
  /// rather than moved, or one on a volume that is not mounted.
  static Future<ResolvedFile?> resolveBookmark(String bookmark) async {
    final result = await _channel
        .invokeMapMethod<Object?, Object?>('resolveBookmark', {
      'bookmark': bookmark,
    });
    if (result == null) return null;
    return ResolvedFile(
      path: result['path'] as String,
      granted: result['granted'] as bool? ?? false,
      stale: result['stale'] as bool? ?? false,
      refreshedBookmark: result['bookmark'] as String?,
    );
  }

  /// Releases a scope opened by [resolveBookmark]. Safe on a path that was
  /// never resolved.
  static Future<void> stopAccess(String path) =>
      _channel.invokeMethod<void>('stopAccess', {'path': path});

  static List<GrantedFile> _filesFrom(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final entry in raw)
        if (entry is Map)
          GrantedFile(
            path: entry['path'] as String,
            bookmark: entry['bookmark'] as String?,
          ),
    ];
  }
}
