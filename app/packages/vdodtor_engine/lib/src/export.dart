/// Writing the timeline to a file.
///
/// The engine does the work on a thread of its own, so this is a handle and a
/// poll rather than a future that blocks. Polling rather than a callback into
/// Dart on purpose: a native thread calling back needs a port and a
/// `NativeCallable.listener`, and all it would carry is a frame count that a
/// progress bar repaints at its own rate anyway.
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'bindings.g.dart';
import 'engine.dart';
import 'native.dart';
import 'timeline_native.dart';

/// What the picture is coded as. Order matches `VdExportCodec` in vd_export.h
/// — the index crosses the FFI boundary as an integer, so append only.
enum ExportCodec {
  /// Plays everywhere, including on things older than the machine it was made
  /// on.
  h264('H.264'),

  /// About half the size for the same picture, and every Apple device and
  /// current browser opens it.
  hevc('HEVC');

  const ExportCodec(this.label);

  final String label;
}

/// How the file should be written. See `VdExportSettings`.
@immutable
class ExportSettings {
  const ExportSettings({
    this.codec = ExportCodec.h264,
    this.videoBitrate = 0,
    this.audioBitrate = 0,
    this.includeAudio = true,
  });

  final ExportCodec codec;

  /// Bits per second for the picture, or 0 for what the size and rate deserve.
  final int videoBitrate;

  /// Bits per second for the sound, or 0 for 192 kbps.
  final int audioBitrate;

  final bool includeAudio;
}

/// Where an export has got to. Mirrors `VdExportState`.
enum ExportState { running, done, cancelled, failed }

/// A snapshot of one export.
@immutable
class ExportProgress {
  const ExportProgress({
    required this.state,
    required this.framesWritten,
    required this.framesTotal,
    required this.positionTicks,
    required this.error,
    required this.elapsedMs,
  });

  static const idle = ExportProgress(
    state: ExportState.running,
    framesWritten: 0,
    framesTotal: 0,
    positionTicks: 0,
    error: 0,
    elapsedMs: 0,
  );

  final ExportState state;
  final int framesWritten;
  final int framesTotal;

  /// Where on the timeline the last written frame was.
  final int positionTicks;

  /// A negative `VdResult` once [state] is [ExportState.failed].
  final int error;

  final double elapsedMs;

  bool get isRunning => state == ExportState.running;

  /// 0..1, and 0 before the total is known rather than a division by zero.
  double get fraction =>
      framesTotal <= 0 ? 0 : (framesWritten / framesTotal).clamp(0.0, 1.0);

  /// Seconds still to go at the rate so far, or null before there is enough to
  /// go on. Deliberately null rather than a wild guess: a countdown that says
  /// four hours for the first second of every export is worse than no
  /// countdown.
  double? get secondsRemaining {
    if (!isRunning || framesWritten < 10 || framesTotal <= 0) return null;
    final perFrame = elapsedMs / framesWritten;
    return (framesTotal - framesWritten) * perFrame / 1000;
  }
}

/// One export, running on a native thread.
///
/// Created by [start], watched through [progress], and finished with by
/// [dispose] — which cancels it first if it is still going, and which takes
/// the half-written file with it.
class Exporter extends ChangeNotifier {
  Exporter._(this._handle) {
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  /// Often enough that the bar moves smoothly, rarely enough that it is not
  /// what the export is spending its time on.
  static const _pollInterval = Duration(milliseconds: 100);

  Pointer<VdExport> _handle;
  Timer? _timer;
  ExportProgress _progress = ExportProgress.idle;

  ExportProgress get progress => _progress;

  /// Starts writing [timeline] to [path].
  ///
  /// Throws [EngineException] when the export cannot be started at all — a
  /// folder that cannot be written to, a codec this machine has no encoder
  /// for, a timeline of no length. Everything that can be known up front is
  /// known here rather than reported as a failure a second later.
  static Exporter start(
    EngineTimeline timeline,
    String path, {
    ExportSettings settings = const ExportSettings(),
  }) {
    final arena = Arena();
    final resultPtr = calloc<Int32>();
    try {
      final native = nativeTimeline(arena, timeline);
      final nativeSettings = arena<VdExportSettings>();
      nativeSettings.ref
        ..codecAsInt = settings.codec.index
        ..video_bitrate = settings.videoBitrate
        ..audio_bitrate = settings.audioBitrate
        ..include_audio = settings.includeAudio;

      final handle = bindings.vd_export_start(
        native,
        path.toNativeUtf8(allocator: arena).cast<Char>(),
        nativeSettings.ref,
        resultPtr,
      );
      if (handle == nullptr) {
        throw EngineException(_messageFor(resultPtr.value),
            code: resultPtr.value, path: path);
      }
      return Exporter._(handle);
    } finally {
      calloc.free(resultPtr);
      arena.releaseAll();
    }
  }

  /// Bytes free on the volume [path] would be written to, or null when that
  /// cannot be answered — which a caller should read as "do not warn" rather
  /// than as "no room".
  static int? freeBytes(String path) {
    final native = path.toNativeUtf8();
    try {
      final free = bindings.vd_export_free_bytes(native.cast<Char>());
      return free < 0 ? null : free;
    } finally {
      calloc.free(native);
    }
  }

  /// Asks it to stop. The state reaches [ExportState.cancelled] within a
  /// frame, and the partial file is removed.
  void cancel() {
    if (_handle == nullptr) return;
    bindings.vd_export_cancel(_handle);
  }

  void _poll() {
    if (_handle == nullptr) return;
    final out = calloc<VdExportProgress>();
    try {
      bindings.vd_export_progress(_handle, out);
      final p = out.ref;
      _progress = ExportProgress(
        state: p.state >= 0 && p.state < ExportState.values.length
            ? ExportState.values[p.state]
            : ExportState.running,
        framesWritten: p.frames_written,
        framesTotal: p.frames_total,
        positionTicks: p.position,
        error: p.error,
        elapsedMs: p.elapsed_ms,
      );
    } finally {
      calloc.free(out);
    }
    if (!_progress.isRunning) {
      _timer?.cancel();
      _timer = null;
    }
    notifyListeners();
  }

  /// What went wrong, in a sentence somebody can act on. The codes are
  /// `VdResult` in vd_probe.h.
  static String _messageFor(int code) => switch (code) {
        -1 => 'that file could not be created',
        -3 => 'this project has nothing to export',
        -4 => 'this Mac has no encoder for that format',
        _ => 'the export could not be started',
      };

  /// The message for a failure that happened after the export started.
  String get failureMessage => _messageFor(_progress.error);

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_handle != nullptr) {
      // Cancels first if it is still running, joins the thread, and takes any
      // half-written file with it.
      bindings.vd_export_destroy(_handle);
      _handle = nullptr;
    }
    super.dispose();
  }
}
