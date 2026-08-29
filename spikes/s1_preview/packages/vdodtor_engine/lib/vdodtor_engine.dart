// Dart side of the S1 spike engine.
//
// Transport control goes straight to the native library over dart:ffi.
// The method channel is used once, to register the external texture, because
// only the plugin registrar can hand out a Flutter texture id.

import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// Mirrors `VdStats` in vd_engine.h — field order and types must match.
final class _VdStats extends Struct {
  @Int64() external int framesDecoded;
  @Int64() external int framesPresented;
  @Int64() external int framesDropped;
  @Double() external double decodeMsAvg;
  @Double() external double compositeMsAvg;
  @Double() external double presentFps;
  @Int64() external int positionNs;
  @Int64() external int durationNs;
  @Int32() external int width;
  @Int32() external int height;
  @Int32() external int outWidth;
  @Int32() external int outHeight;
  @Int32() external int state;
  @Int32() external int layers;
  @Double() external double lastSeekMs;
  @Double() external double cpuPercent;
}

/// Immutable snapshot of engine counters.
class EngineStats {
  final int framesDecoded, framesPresented, framesDropped;
  final double decodeMsAvg, compositeMsAvg, presentFps;
  final int positionNs, durationNs;
  final int width, height, outWidth, outHeight, state, layers;
  final double lastSeekMs, cpuPercent;

  const EngineStats({
    required this.framesDecoded,
    required this.framesPresented,
    required this.framesDropped,
    required this.decodeMsAvg,
    required this.compositeMsAvg,
    required this.presentFps,
    required this.positionNs,
    required this.durationNs,
    required this.width,
    required this.height,
    required this.outWidth,
    required this.outHeight,
    required this.state,
    required this.layers,
    required this.lastSeekMs,
    required this.cpuPercent,
  });

  static const empty = EngineStats(
    framesDecoded: 0, framesPresented: 0, framesDropped: 0,
    decodeMsAvg: 0, compositeMsAvg: 0, presentFps: 0,
    positionNs: 0, durationNs: 0, width: 0, height: 0,
    outWidth: 0, outHeight: 0, state: 0, layers: 1,
    lastSeekMs: 0, cpuPercent: 0,
  );

  String get stateName => switch (state) {
        0 => 'idle',
        1 => 'playing',
        2 => 'paused',
        3 => 'eof',
        _ => 'error',
      };

  /// One-line form used by the benchmark log.
  String toLogLine() => 'fps=${presentFps.toStringAsFixed(1)} '
      'dec=${decodeMsAvg.toStringAsFixed(2)}ms '
      'gpu=${compositeMsAvg.toStringAsFixed(2)}ms '
      'cpu=${cpuPercent.toStringAsFixed(0)}% '
      'frames=$framesPresented dropped=$framesDropped '
      'layers=$layers out=${outWidth}x$outHeight '
      'pos=${(positionNs / 1e9).toStringAsFixed(2)}s $stateName';
}

// ---------------------------------------------------------------- ffi types

typedef _CreateNative = Pointer<Void> Function();
typedef _Create = Pointer<Void> Function();

typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _Destroy = void Function(Pointer<Void>);

typedef _OpenNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32, Int32);
typedef _Open = int Function(Pointer<Void>, Pointer<Utf8>, int, int);

typedef _VoidCallNative = Void Function(Pointer<Void>);
typedef _VoidCall = void Function(Pointer<Void>);

typedef _SeekNative = Void Function(Pointer<Void>, Int64);
typedef _Seek = void Function(Pointer<Void>, int);

typedef _LayersNative = Void Function(Pointer<Void>, Int32);
typedef _Layers = void Function(Pointer<Void>, int);

typedef _DumpNative = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _Dump = int Function(Pointer<Void>, Pointer<Utf8>);

typedef _StatsNative = Void Function(Pointer<Void>, Pointer<_VdStats>);
typedef _Stats = void Function(Pointer<Void>, Pointer<_VdStats>);

/// Handle to one native engine instance.
class VdodtorEngine {
  static const MethodChannel _channel = MethodChannel('vdodtor_engine');

  // The plugin is linked into the running process, so its symbols are here.
  static final DynamicLibrary _lib = DynamicLibrary.process();

  static final _create = _lib.lookupFunction<_CreateNative, _Create>('vd_engine_create');
  static final _destroy = _lib.lookupFunction<_DestroyNative, _Destroy>('vd_engine_destroy');
  static final _open = _lib.lookupFunction<_OpenNative, _Open>('vd_engine_open');
  static final _play = _lib.lookupFunction<_VoidCallNative, _VoidCall>('vd_engine_play');
  static final _pause = _lib.lookupFunction<_VoidCallNative, _VoidCall>('vd_engine_pause');
  static final _seek = _lib.lookupFunction<_SeekNative, _Seek>('vd_engine_seek_ns');
  static final _setLayers = _lib.lookupFunction<_LayersNative, _Layers>('vd_engine_set_layers');
  static final _stats = _lib.lookupFunction<_StatsNative, _Stats>('vd_engine_stats');
  static final _dumpPng = _lib.lookupFunction<_DumpNative, _Dump>('vd_engine_dump_png');

  final Pointer<Void> _ptr;
  final Pointer<_VdStats> _statsBuf = calloc<_VdStats>();
  int? textureId;

  VdodtorEngine._(this._ptr);

  /// Creates the native engine. Throws if Metal or shader setup failed.
  factory VdodtorEngine.create() {
    final p = _create();
    if (p == nullptr) throw StateError('vd_engine_create failed (no Metal device?)');
    return VdodtorEngine._(p);
  }

  /// Opens [path] and starts decoding. [outWidth]/[outHeight] set the
  /// composite output size; 0 means match the source.
  int open(String path, {int outWidth = 0, int outHeight = 0}) {
    final c = path.toNativeUtf8();
    try {
      return _open(_ptr, c, outWidth, outHeight);
    } finally {
      calloc.free(c);
    }
  }

  /// Registers the engine output as a Flutter external texture.
  Future<int> registerTexture() async {
    final id = await _channel.invokeMethod<int>('registerTexture', {'engine': _ptr.address});
    textureId = id;
    return id!;
  }

  void play() => _play(_ptr);
  void pause() => _pause(_ptr);
  void seekNs(int positionNs) => _seek(_ptr, positionNs);
  void seekSeconds(double s) => _seek(_ptr, (s * 1e9).round());
  void setLayers(int n) => _setLayers(_ptr, n);

  /// Writes the latest composited frame to [path] as PNG (verification aid).
  int dumpPng(String path) {
    final c = path.toNativeUtf8();
    try {
      return _dumpPng(_ptr, c);
    } finally {
      calloc.free(c);
    }
  }

  EngineStats stats() {
    _stats(_ptr, _statsBuf);
    final s = _statsBuf.ref;
    return EngineStats(
      framesDecoded: s.framesDecoded,
      framesPresented: s.framesPresented,
      framesDropped: s.framesDropped,
      decodeMsAvg: s.decodeMsAvg,
      compositeMsAvg: s.compositeMsAvg,
      presentFps: s.presentFps,
      positionNs: s.positionNs,
      durationNs: s.durationNs,
      width: s.width,
      height: s.height,
      outWidth: s.outWidth,
      outHeight: s.outHeight,
      state: s.state,
      layers: s.layers,
      lastSeekMs: s.lastSeekMs,
      cpuPercent: s.cpuPercent,
    );
  }

  Future<void> dispose() async {
    if (textureId != null) {
      await _channel.invokeMethod('unregisterTexture', {'textureId': textureId});
      textureId = null;
    }
    _destroy(_ptr);
    calloc.free(_statsBuf);
  }
}
