import 'dart:ffi';

import 'bindings.g.dart';

/// The engine is force-loaded into the plugin framework, which the app links,
/// so its symbols are already in the process. There is no library to open.
final VdEngineBindings bindings = VdEngineBindings(DynamicLibrary.process());

/// Raised when the engine cannot do what was asked. Carries the native result
/// code so a log line can be matched to `VdResult` in vd_probe.h.
final class EngineException implements Exception {
  const EngineException(this.message, {this.code, this.path});

  final String message;
  final int? code;
  final String? path;

  @override
  String toString() => 'EngineException: $message'
      '${path == null ? '' : ' ($path)'}'
      '${code == null ? '' : ' [code $code]'}';
}
