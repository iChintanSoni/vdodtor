/// One small picture of a media file, rendered by the same compositor that
/// draws the preview.
library;

import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.g.dart';
import 'native.dart';

/// Raw pixels, ready for `decodeImageFromPixels`.
final class NativeThumbnail {
  const NativeThumbnail({
    required this.width,
    required this.height,
    required this.bgra,
  });

  final int width;
  final int height;

  /// Tightly packed BGRA — `width * height * 4` bytes, no row padding.
  final Uint8List bgra;

  @override
  String toString() => 'NativeThumbnail(${width}x$height)';
}

/// The engine has no video stream to draw. Audio files land here, and so does
/// anything whose picture cannot be decoded.
const int _noVideoStream = -4; // VD_ERR_UNSUPPORTED

/// Rendering thumbnails.
abstract final class Thumbnails {
  /// Renders the frame at [ticks] from [path], fitted inside
  /// [maxWidth] x [maxHeight], on a background isolate.
  ///
  /// Off the UI isolate because this decodes: reaching a frame in the middle
  /// of long-GOP footage costs hundreds of milliseconds, and a media bin that
  /// stutters the editor while it fills in is worse than one that fills in
  /// slowly.
  ///
  /// Returns null for a file with no picture — an audio asset is a normal
  /// thing to have in the bin, not a failure. Throws [EngineException] when
  /// the file will not open or will not decode.
  static Future<NativeThumbnail?> render(
    String path, {
    int ticks = 0,
    int maxWidth = 320,
    int maxHeight = 320,
  }) =>
      Isolate.run(() => renderSync(
            path,
            ticks: ticks,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
          ));

  /// [render], on the calling isolate. For tests and command-line tools; the
  /// app should not block a frame on a decode.
  static NativeThumbnail? renderSync(
    String path, {
    int ticks = 0,
    int maxWidth = 320,
    int maxHeight = 320,
  }) {
    if (path.isEmpty) throw const EngineException('empty media path');

    return using((arena) {
      final out = arena<VdThumbnail>();
      final nativePath = path.toNativeUtf8(allocator: arena);
      final result = bindings.vd_thumbnail_render(
          nativePath.cast<Char>(), ticks, maxWidth, maxHeight, out);

      if (result == _noVideoStream) return null;
      if (result != 0) {
        throw EngineException(_resultString(result), code: result, path: path);
      }

      try {
        final thumb = out.ref;
        // Copied out before the native buffer is freed: the Dart list has to
        // own its bytes, and it has to own them before this scope ends.
        return NativeThumbnail(
          width: thumb.width,
          height: thumb.height,
          bgra: Uint8List.fromList(
              thumb.pixels.asTypedList(thumb.width * thumb.height * 4)),
        );
      } finally {
        bindings.vd_thumbnail_free(out);
      }
    });
  }

  static String _resultString(int code) {
    final ptr = bindings.vd_result_string(code);
    return ptr == nullptr
        ? 'unknown engine error'
        : ptr.cast<Utf8>().toDartString();
  }
}
