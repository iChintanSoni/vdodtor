import 'package:flutter/foundation.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../ui/timeline/timeline_controller.dart';

/// The preview engine, seen as a playhead.
///
/// A four-line adapter rather than making the engine implement the timeline's
/// interface directly: the engine package holds no app knowledge, and the
/// timeline holds no engine knowledge. This is the seam where they meet, and
/// it is the only place either has to know the other exists.
final class EngineTransport implements TimelineTransport {
  const EngineTransport(this._engine);

  final PreviewEngine _engine;

  @override
  int get positionTicks => _engine.positionTicks;

  @override
  int get durationTicks => _engine.durationTicks;

  @override
  bool get isPlaying => _engine.isPlaying;

  @override
  void seek(int ticks) => _engine.seek(ticks);

  @override
  void addListener(VoidCallback listener) => _engine.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _engine.removeListener(listener);
}
