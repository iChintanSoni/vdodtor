import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../model/media.dart';
import 'peaks.dart';

/// What the timeline knows about one asset's sound.
enum WaveformState {
  /// Not asked for yet.
  unknown,

  /// Being read off disk or analysed.
  pending,

  /// Analysed; [WaveformCache.peaksOf] has it.
  ready,

  /// The file has no sound. Silent video lands here, and it is not a failure —
  /// there is simply no waveform to draw.
  none,

  /// The file would not open, or its audio would not decode.
  failed,
}

/// Analyses one file. Swapped out in tests, which have no engine.
typedef PeakAnalyzer = Future<NativePeaks?> Function(String path);

Future<NativePeaks?> _enginePeaks(String path) => Peaks.analyze(path);

/// Waveforms for the assets on the timeline: read from disk when they have
/// been taken before, analysed once when they have not.
///
/// A [ChangeNotifier] and not a future per clip, for the same reason
/// `ThumbnailCache` is one: the timeline repaints on every transport tick, and
/// a waveform that re-issued an analysis per paint would make playing a
/// project the most expensive thing the app does. Asking twice is free.
///
/// The disk half is what makes this bearable. Analysis reads the whole file's
/// audio — seconds of work for a long recording — so it happens once per file
/// ever, not once per session and not once per project. What is cached is a
/// property of the *file*, never of the clip: volume, fades and mute scale the
/// drawn envelope at paint time, so pulling a fader does not invalidate
/// anything.
class WaveformCache extends ChangeNotifier {
  WaveformCache({
    this.directory,
    PeakAnalyzer? analyzer,
    this.maxBytesInMemory = 64 * 1024 * 1024,
    this.maxBytesOnDisk = 512 * 1024 * 1024,
  }) : _analyze = analyzer ?? _enginePeaks;

  /// Where peak files are kept, or null to work in memory only — which is
  /// what a test gets unless it says otherwise.
  final Directory? directory;

  final PeakAnalyzer _analyze;

  /// How much peak data to hold decoded at once. A pyramid is about 3 KB per
  /// second of audio, so this is roughly six hours of it — a bound in bytes
  /// rather than in files because "twenty waveforms" means 60 KB for twenty
  /// stings and 200 MB for twenty interviews.
  final int maxBytesInMemory;

  /// How much to leave on disk between sessions. Trimmed newest-first when
  /// the cache is opened.
  final int maxBytesOnDisk;

  /// Insertion-ordered, so the first key is the least recently touched.
  final Map<String, PeakPyramid> _peaks = {};
  final Map<String, WaveformState> _states = {};
  final List<MediaAsset> _queue = [];
  final Set<String> _queued = {};
  int _bytes = 0;
  bool _running = false;
  bool _disposed = false;

  PeakPyramid? peaksOf(String assetId) {
    final peaks = _peaks.remove(assetId);
    if (peaks == null) return null;
    _peaks[assetId] = peaks; // touch: move to the most-recent end
    return peaks;
  }

  WaveformState stateOf(String assetId) =>
      _states[assetId] ?? WaveformState.unknown;

  /// Asks for [asset]'s waveform. Returns immediately; listeners are notified
  /// when it arrives. Calling this from a paint is the intended use, which is
  /// why a second call while the first is in flight does nothing.
  void request(MediaAsset asset) {
    if (_disposed) return;
    if (_states.containsKey(asset.id) || _queued.contains(asset.id)) return;
    if (!asset.probe.hasAudio) {
      _states[asset.id] = WaveformState.none;
      return;
    }
    _queued.add(asset.id);
    _queue.add(asset);
    _pump();
  }

  /// Forgets what is known about [assetId] — after a relink, or when the file
  /// changed underneath. The peak file stays; its stamp will decide.
  void forget(String assetId) {
    final peaks = _peaks.remove(assetId);
    if (peaks != null) _bytes -= _sizeOf(peaks);
    _states.remove(assetId);
  }

  /// One at a time, deliberately. Analysis is a full decode of the file, and
  /// an import of a dozen tracks that saturated every core would take the
  /// stutter out of the waveforms and put it into the playback.
  void _pump() {
    if (_running || _queue.isEmpty) return;
    final asset = _queue.removeAt(0);
    _running = true;
    _states[asset.id] = WaveformState.pending;
    unawaited(_loadOne(asset).whenComplete(() {
      _running = false;
      _queued.remove(asset.id);
      _pump();
    }));
  }

  Future<void> _loadOne(MediaAsset asset) async {
    WaveformState state;
    PeakPyramid? peaks;
    try {
      peaks = await _readOrAnalyze(asset.path);
      state = peaks == null ? WaveformState.none : WaveformState.ready;
    } catch (_) {
      // Every reason a waveform fails — a file that moved, a codec the engine
      // will not decode, a permission the sandbox withdrew — is the same
      // reason as far as the timeline is concerned: draw the clip without one.
      state = WaveformState.failed;
    }

    if (_disposed) return;
    _states[asset.id] = state;
    if (peaks != null) {
      final previous = _peaks.remove(asset.id);
      if (previous != null) _bytes -= _sizeOf(previous);
      _peaks[asset.id] = peaks;
      _bytes += _sizeOf(peaks);
      _evict();
    }
    notifyListeners();
  }

  Future<PeakPyramid?> _readOrAnalyze(String path) async {
    final stamp = await MediaStamp.of(path);
    final file = _fileFor(path);

    if (file != null && stamp.isKnown) {
      final cached = await _read(file, stamp);
      if (cached != null) return cached;
    }

    final native = await _analyze(path);
    if (native == null) return null;
    final peaks = PeakPyramid.fromNative(native, stamp: stamp);
    if (file != null && stamp.isKnown) await _write(file, peaks);
    return peaks;
  }

  Future<PeakPyramid?> _read(File file, MediaStamp stamp) async {
    try {
      if (!await file.exists()) return null;
      final peaks = PeakFile.decode(await file.readAsBytes());
      // A peak file that names a different version of the media is not an
      // error, it is out of date. Deleting it here rather than leaving it to
      // the size sweep keeps one entry per file rather than one per edit.
      if (!stamp.matches(peaks.stamp)) {
        await file.delete();
        return null;
      }
      return peaks;
    } on PeakFormatException {
      // Not ours, or from a version that no longer exists. Analysing again is
      // the whole recovery story a cache needs.
      try {
        await file.delete();
      } on FileSystemException {
        // Nothing to do about a cache file that will not go away.
      }
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _write(File file, PeakPyramid peaks) async {
    try {
      await file.parent.create(recursive: true);
      // Written aside and renamed: a crash mid-write would otherwise leave a
      // half a peak file, and the next run would read a truncated waveform as
      // a short one rather than as a broken one.
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsBytes(PeakFile.encode(peaks), flush: true);
      await temporary.rename(file.path);
    } on FileSystemException {
      // A cache that cannot be written is a slow cache, not a broken app.
    }
  }

  /// The peak file for [path].
  ///
  /// Named after the file it describes so the directory can be read by a
  /// person, and hashed so that two files with the same name in different
  /// folders do not collide. A hash collision costs a re-analysis and nothing
  /// else — the stamp inside the file is what decides whether it is the right
  /// waveform, never the name.
  File? _fileFor(String path) {
    final directory = this.directory;
    if (directory == null) return null;
    final name = path.split(Platform.pathSeparator).last;
    final safe = name
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .padRight(1, '_');
    final short = safe.length <= 48 ? safe : safe.substring(0, 48);
    return File('${directory.path}/$short-${_hash(path)}.vdpk');
  }

  /// FNV-1a, 64-bit, kept to 63 so it stays positive on every platform.
  ///
  /// A hash for a filename, not for a signature: nothing here is trusting it,
  /// so a real digest would be a dependency bought for nothing.
  static String _hash(String value) {
    var hash = 0xcbf29ce484222325;
    for (final unit in value.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
      hash &= 0x7fffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  static int _sizeOf(PeakPyramid peaks) => peaks.buckets.lengthInBytes;

  void _evict() {
    while (_bytes > maxBytesInMemory && _peaks.length > 1) {
      final oldest = _peaks.keys.first;
      final peaks = _peaks.remove(oldest);
      if (peaks != null) _bytes -= _sizeOf(peaks);
      _states.remove(oldest);
    }
  }

  /// Trims the peak directory to [maxBytesOnDisk], newest first.
  ///
  /// Called once when a project opens rather than on every write: the cost of
  /// keeping a waveform is a few megabytes and the cost of losing one is
  /// several seconds of decoding, so this should run rarely and take the
  /// oldest files when it does.
  Future<void> prune() async {
    final directory = this.directory;
    if (directory == null) return;
    try {
      if (!await directory.exists()) return;
      final files = <({File file, DateTime modified, int size})>[];
      await for (final entry in directory.list()) {
        if (entry is! File || !entry.path.endsWith('.vdpk')) continue;
        final stat = await entry.stat();
        files.add((file: entry, modified: stat.modified, size: stat.size));
      }
      files.sort((a, b) => b.modified.compareTo(a.modified));

      var kept = 0;
      for (final entry in files) {
        kept += entry.size;
        if (kept > maxBytesOnDisk) await entry.file.delete();
      }
    } on FileSystemException {
      // A cache that will not tidy itself is not worth failing an open over.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _peaks.clear();
    _states.clear();
    _queue.clear();
    _queued.clear();
    _bytes = 0;
    super.dispose();
  }
}
