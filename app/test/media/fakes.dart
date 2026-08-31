import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/engine/media_probe.dart';
import 'package:vdodtor/media/file_access.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/time.dart';

/// A file panel and a sandbox that do what the test says.
class FakeFileAccess implements FileAccess {
  FakeFileAccess({
    this.picks = const [],
    this.bookmarksWork = true,
    Map<String, ResolvedFile?> resolutions = const {},
  }) : resolutions = Map.of(resolutions);

  /// What the next [pick] returns.
  List<GrantedFile> picks;

  /// False for a sandbox that will not mint bookmarks — the case where an
  /// import still has to work for this run.
  bool bookmarksWork;

  /// Bookmark data to the file it names. Anything not listed does not resolve.
  final Map<String, ResolvedFile?> resolutions;

  final List<String> bookmarked = [];
  final List<String> resolved = [];
  final List<String> released = [];
  int pickCount = 0;

  @override
  Future<List<GrantedFile>> pick() async {
    pickCount++;
    return picks;
  }

  @override
  Future<String?> bookmark(String path) async {
    bookmarked.add(path);
    return bookmarksWork ? 'bm:$path' : null;
  }

  @override
  Future<ResolvedFile?> resolve(String bookmark) async {
    resolved.add(bookmark);
    return resolutions[bookmark];
  }

  @override
  Future<void> release(String path) async => released.add(path);
}

/// An engine probe that answers from a table instead of from a file.
class FakeProber implements MediaProber {
  FakeProber(this.answers);

  /// Path to what is in it. A path that is absent comes back as an error, the
  /// way a file the engine cannot read does.
  final Map<String, MediaProbe> answers;

  final List<List<String>> batches = [];

  @override
  Future<List<ProbeOutcome>> probeAll(List<String> paths) async {
    batches.add(List.of(paths));
    return [
      for (final path in paths)
        answers.containsKey(path)
            ? (path: path, probe: answers[path], error: null)
            : (path: path, probe: null, error: 'could not open the file'),
    ];
  }
}

/// A probe of a plain video file.
MediaProbe videoProbe({double seconds = 4, bool audio = true}) => MediaProbe(
      kind: MediaKind.video,
      duration: Timebase.project.fromSeconds(Rational((seconds * 1000).round(), 1000)),
      width: 1920,
      height: 1080,
      frameRate: FrameRates.fps30,
      hasVideo: true,
      hasAudio: audio,
      audioChannels: audio ? 2 : 0,
      audioSampleRate: audio ? 48000 : 0,
      videoCodec: 'h264',
      audioCodec: audio ? 'aac' : null,
    );

MediaProbe audioProbe({double seconds = 30}) => MediaProbe(
      kind: MediaKind.audio,
      duration: Timebase.project.fromSeconds(Rational((seconds * 1000).round(), 1000)),
      hasAudio: true,
      audioChannels: 2,
      audioSampleRate: 48000,
      audioCodec: 'aac',
    );

/// An image: real dimensions, no duration of its own.
MediaProbe imageProbe() => const MediaProbe(
      kind: MediaKind.image,
      duration: Tick.zero,
      width: 1200,
      height: 800,
      hasVideo: true,
    );

/// A container that opened but holds nothing to play — the failure mode that
/// is not a failure to open.
MediaProbe nothingPlayableProbe() => const MediaProbe(
      kind: MediaKind.video,
      duration: Tick.zero,
    );

/// Waits for [done], pumping the event loop.
///
/// The media caches are asynchronous by design — a thumbnail decodes on an
/// isolate, a waveform reads a file and then decodes a whole track — and what
/// these tests are about is what they do across those awaits.
Future<void> pumpUntil(bool Function() done, {int rounds = 400}) async {
  for (var i = 0; i < rounds && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(done(), isTrue, reason: 'timed out waiting for the cache');
}
