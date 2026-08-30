import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../model/media.dart';
import '../model/time.dart';

/// What the bin knows about one asset's picture.
enum ThumbnailState {
  /// Not asked for yet.
  unknown,

  /// Being decoded.
  pending,

  /// Decoded; [ThumbnailCache.imageOf] has it.
  ready,

  /// The file has no picture — an audio asset. Not a failure; the bin draws a
  /// waveform mark instead.
  none,

  /// The file would not open or would not decode.
  failed,
}

/// Renders one thumbnail. Swapped out in tests, which have no engine.
typedef ThumbnailRenderer = Future<NativeThumbnail?> Function(
    String path, int ticks, int maxSize);

Future<NativeThumbnail?> _engineRenderer(
        String path, int ticks, int maxSize) =>
    Thumbnails.render(path,
        ticks: ticks, maxWidth: maxSize, maxHeight: maxSize);

/// A frame far enough in to be worth looking at.
///
/// Not frame zero: a lot of footage starts on black, or on a lens cap, and a
/// bin of black rectangles is a bin nobody can read. Not the midpoint either —
/// a seek costs whatever the source's keyframe spacing costs, and one second
/// in is usually the first or second keyframe.
Tick thumbnailTick(MediaProbe probe) {
  if (probe.duration.raw <= 0) return Tick.zero;
  final oneSecond = Timebase.project.fromSeconds(Rational.one);
  final half = Tick(probe.duration.raw ~/ 2);
  return half.raw < oneSecond.raw ? half : oneSecond;
}

/// Pictures of the assets in the bin, decoded once and kept.
///
/// A [ChangeNotifier] rather than a future per widget: a bin row is rebuilt
/// whenever anything about the project changes, and re-issuing a decode on
/// every rebuild would make scrolling the bin the most expensive thing the app
/// does. Asking twice for the same asset is free.
class ThumbnailCache extends ChangeNotifier {
  ThumbnailCache({
    this.maxSize = 320,
    this.capacity = 96,
    this.concurrency = 2,
    ThumbnailRenderer? renderer,
  }) : _render = renderer ?? _engineRenderer;

  /// Longest edge of a rendered thumbnail, in pixels.
  final int maxSize;

  /// How many decoded images to keep. Past this the least recently asked-for
  /// is disposed.
  final int capacity;

  /// Decodes in flight at once. Each one is an isolate holding a decoder and a
  /// Metal compositor, so this is a memory bound as much as a CPU one.
  final int concurrency;

  final ThumbnailRenderer _render;

  /// Insertion-ordered, so the first key is the least recently touched.
  final Map<String, ui.Image> _images = {};
  final Map<String, ThumbnailState> _states = {};
  final List<MediaAsset> _queue = [];
  final Set<String> _queued = {};
  int _running = 0;
  bool _disposed = false;

  ui.Image? imageOf(String assetId) {
    final image = _images.remove(assetId);
    if (image == null) return null;
    _images[assetId] = image; // touch: move to the most-recent end
    return image;
  }

  ThumbnailState stateOf(String assetId) =>
      _states[assetId] ?? ThumbnailState.unknown;

  /// Asks for [asset]'s picture. Returns immediately; listeners are notified
  /// when it arrives. Calling this from a build method is the intended use,
  /// which is why a second call while the first is in flight does nothing.
  void request(MediaAsset asset) {
    if (_disposed) return;
    if (_states.containsKey(asset.id) || _queued.contains(asset.id)) return;
    if (!asset.probe.hasVideo) {
      _states[asset.id] = ThumbnailState.none;
      return;
    }
    _queued.add(asset.id);
    _queue.add(asset);
    _pump();
  }

  /// Forgets what is known about [assetId] — after a relink, or when the file
  /// changed underneath.
  void forget(String assetId) {
    _images.remove(assetId)?.dispose();
    _states.remove(assetId);
  }

  void _pump() {
    while (_running < concurrency && _queue.isNotEmpty) {
      final asset = _queue.removeAt(0);
      _running++;
      _states[asset.id] = ThumbnailState.pending;
      unawaited(_renderOne(asset).whenComplete(() {
        _running--;
        _queued.remove(asset.id);
        _pump();
      }));
    }
  }

  Future<void> _renderOne(MediaAsset asset) async {
    ThumbnailState state;
    ui.Image? image;
    try {
      final native = await _render(
          asset.path, thumbnailTick(asset.probe).raw, maxSize);
      if (native == null) {
        state = ThumbnailState.none;
      } else {
        image = await _decode(native);
        state = ThumbnailState.ready;
      }
    } catch (_) {
      // Every reason a thumbnail fails — a moved file, a codec the engine will
      // not decode, a permission the sandbox withdrew — is the same reason as
      // far as the bin is concerned: draw the placeholder, keep the row.
      state = ThumbnailState.failed;
    }

    if (_disposed) {
      image?.dispose();
      return;
    }

    _states[asset.id] = state;
    if (image != null) {
      _images.remove(asset.id)?.dispose();
      _images[asset.id] = image;
      _evict();
    }
    notifyListeners();
  }

  void _evict() {
    while (_images.length > capacity) {
      final oldest = _images.keys.first;
      _images.remove(oldest)?.dispose();
      _states.remove(oldest);
    }
  }

  static Future<ui.Image> _decode(NativeThumbnail thumb) {
    final completer = Completer<ui.Image>();
    // BGRA straight from the compositor's output buffer, opaque, unpadded —
    // which is exactly one of the formats this takes, so there is no
    // conversion between the GPU and the screen.
    ui.decodeImageFromPixels(
      thumb.bgra,
      thumb.width,
      thumb.height,
      ui.PixelFormat.bgra8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _queue.clear();
    _queued.clear();
    super.dispose();
  }
}
