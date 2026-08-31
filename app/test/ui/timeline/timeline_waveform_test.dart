import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/media/waveforms.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';
import 'package:vdodtor/ui/timeline/timeline_geometry.dart';
import 'package:vdodtor/ui/timeline/timeline_painter.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../../fixtures.dart';
import '../../media/fakes.dart' show pumpUntil;
import '../../media/peak_fixtures.dart';
import 'timeline_controller_test.dart' show FakeTransport;

/// The timeline drawn onto a real canvas, so what the assertions read is what
/// the screen would show. Everything below is about *where* ink lands inside a
/// clip, and no amount of inspecting the painter's arguments would say that.
void main() {
  // A binding, but no widget tree: `Picture.toImage` needs one, and the fake
  // clock a `testWidgets` body runs under would never let the cache's futures
  // complete.
  TestWidgetsFlutterBinding.ensureInitialized();

  const size = Size(700, 200);

  /// A steady tone: every bucket the same height, so the drawn band has a
  /// height a test can measure rather than a shape it has to recognise.
  NativePeaks steady({double level = 0.9, double seconds = 6}) {
    final buckets = (seconds * 48000 / 128).round();
    return nativePyramid([for (var i = 0; i < buckets; i++) (-level, level)]);
  }

  /// A project with one four-second music clip on the audio lane.
  Project withMusic({ClipAudio audio = ClipAudio.unity}) {
    final project = emptyProject().addMedia(audioAsset('song', seconds: 6));
    return project.updateTrack(
      audioTrackId,
      (t) => t.withClips([
        clipOf('bed', 'song', start: Tick.zero, duration: secs(4))
            .copyWith(audio: audio),
      ]),
    );
  }

  Future<Uint8List> render(Project project, WaveformCache? waveforms) async {
    final store = DocumentStore(project);
    final controller = TimelineController(
      store: store,
      transport: FakeTransport(durationTicks: secs(10).raw),
    );
    addTearDown(() {
      controller.dispose();
      store.dispose();
    });

    // The painter asks for a waveform while it paints, which is the right
    // shape for a widget that repaints constantly and the wrong shape for a
    // test: the first paint would always be the one before the analysis lands.
    if (waveforms != null) {
      for (final asset in project.media.values) {
        waveforms.request(asset);
      }
      await pumpUntil(() => project.media.values
          .every((a) => waveforms.stateOf(a.id) != WaveformState.pending));
    }

    final recorder = ui.PictureRecorder();
    TimelinePainter(controller, waveforms: waveforms)
        .paint(Canvas(recorder), size);
    final image = await recorder
        .endRecording()
        .toImage(size.width.round(), size.height.round());
    addTearDown(image.dispose);
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List();
  }

  int pixelAt(Uint8List rgba, int x, int y) {
    final at = (y * size.width.round() + x) * 4;
    return (rgba[at] << 16) | (rgba[at + 1] << 8) | rgba[at + 2];
  }

  /// Rows in column [x] between [from] and [to] that are not the clip's flat
  /// fill — that is, rows the waveform put ink on.
  ///
  /// The two rows at each edge are skipped: the clip is a rounded rectangle
  /// and its own antialiased border is not the waveform.
  List<int> inkedRows(Uint8List rgba, int x, int from, int to, int fill) => [
        for (var y = from + 2; y <= to - 2; y++)
          if (pixelAt(rgba, x, y) != fill) y,
      ];

  // The audio lane is the second one down; its clip body is inset three
  // pixels from the lane and the waveform band five more.
  const geometry = TimelineGeometry();
  final laneTop = geometry.topOfTrack(1).round();
  final bodyTop = laneTop + 3;
  final bodyBottom = laneTop + TimelineGeometry.trackHeight.round() - 3;
  final bandCentre = (bodyTop + bodyBottom) ~/ 2;

  /// Well past the clip's label, and nowhere near the playhead at zero.
  const column = TimelineGeometry.headerWidth + 220;

  /// The same, for the main track, where the clip also carries a second line
  /// of detail text that reaches further in.
  const videoColumn = TimelineGeometry.headerWidth + 380;

  test('an audio clip is drawn with its waveform', () async {
    final cache = WaveformCache(analyzer: (path) async => steady());
    addTearDown(cache.dispose);

    final rgba = await render(withMusic(), cache);
    final fill = pixelAt(rgba, column.round(), bodyTop + 1);
    final inked = inkedRows(rgba, column.round(), bodyTop, bodyBottom, fill);

    // A band around the centre line, most of the height the clip gives it.
    expect(inked, isNotEmpty);
    expect(inked.last - inked.first, greaterThan(20));
    expect(inked.first, lessThan(bandCentre));
    expect(inked.last, greaterThan(bandCentre));
  });

  test('no waveform cache means no waveform, and no complaint', () async {
    final rgba = await render(withMusic(), null);
    final fill = pixelAt(rgba, column.round(), bodyTop + 1);

    expect(inkedRows(rgba, column.round(), bodyTop, bodyBottom, fill), isEmpty);
  });

  test('a quieter clip is drawn shorter', () async {
    final loud = WaveformCache(analyzer: (path) async => steady());
    final quiet = WaveformCache(analyzer: (path) async => steady());
    addTearDown(loud.dispose);
    addTearDown(quiet.dispose);

    final atFull = await render(withMusic(), loud);
    final atQuarter = await render(
        withMusic(audio: const ClipAudio(volume: 0.25)), quiet);

    int height(Uint8List rgba) {
      final fill = pixelAt(rgba, column.round(), bodyTop + 1);
      final inked = inkedRows(rgba, column.round(), bodyTop, bodyBottom, fill);
      return inked.isEmpty ? 0 : inked.last - inked.first;
    }

    // The envelope is the file's and the height is the clip's, which is what
    // makes a fader instant rather than a re-analysis.
    expect(height(atQuarter), lessThan(height(atFull) / 2));
    expect(height(atQuarter), greaterThan(0));
  });

  test('a muted clip is a flat line, not a blank clip', () async {
    final cache = WaveformCache(analyzer: (path) async => steady());
    addTearDown(cache.dispose);

    final rgba =
        await render(withMusic(audio: const ClipAudio(muted: true)), cache);
    final fill = pixelAt(rgba, column.round(), bodyTop + 1);
    final inked = inkedRows(rgba, column.round(), bodyTop, bodyBottom, fill);

    // Something is drawn — a lane that went blank where a clip was muted would
    // read as missing media — and it is flat, through the middle.
    expect(inked, isNotEmpty);
    expect(inked.last - inked.first, lessThan(4));
    expect(inked.first, closeTo(bandCentre, 3));
  });

  test('a video clip wears its waveform along the bottom', () async {
    final cache = WaveformCache(analyzer: (path) async => steady());
    addTearDown(cache.dispose);

    final project = projectWithThreeClips();
    final rgba = await render(project, cache);

    // The main track is the first lane, and its second clip runs 2s–5s.
    final top = geometry.topOfTrack(0).round() + 3;
    final bottom = geometry.topOfTrack(0).round() +
        TimelineGeometry.trackHeight.round() - 3;
    final fill = pixelAt(rgba, videoColumn.round(), top + 1);
    final inked = inkedRows(rgba, videoColumn.round(), top, bottom, fill);

    expect(inked, isNotEmpty);
    // Along the bottom, not through the middle: what identifies a video clip
    // is its name, and its sound is the thing you look for underneath.
    expect(inked.first, greaterThan((top + bottom) / 2));
  });
}
