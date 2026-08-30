import '../model/time.dart';

/// `mm:ss:ff` on the project's own frame rate.
///
/// Frames, not decimals: an editor's unit of time is the frame, and a
/// position shown as 3.47 s cannot be typed back in or compared to a cut.
String timecode(int ticks, Rational fps) {
  final totalFrames = Timebase.project.frameOfTick(Tick(ticks), fps);
  final perSecond = (fps.numerator / fps.denominator).round();
  final frames = totalFrames % perSecond;
  final totalSeconds = totalFrames ~/ perSecond;
  final seconds = totalSeconds % 60;
  final minutes = totalSeconds ~/ 60;
  return '${_two(minutes)}:${_two(seconds)}:${_two(frames)}';
}

/// `mm:ss`, or `h:mm:ss` past an hour — the ruler's form, where the frame
/// number is noise at every zoom that shows more than a second at a time.
String clockLabel(int ticks) {
  final totalSeconds = ticks ~/ Timebase.project.ticksPerSecond;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  return hours > 0
      ? '$hours:${_two(minutes)}:${_two(seconds)}'
      : '${_two(minutes)}:${_two(seconds)}';
}

String _two(int v) => v.toString().padLeft(2, '0');
