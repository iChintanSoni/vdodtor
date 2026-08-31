import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/peaks.dart';
import 'package:vdodtor/media/waveforms.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import 'fakes.dart';
import 'peak_fixtures.dart';

void main() {
  late Directory root;
  late Directory cacheDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vd_peaks_test');
    cacheDir = Directory('${root.path}/Peaks');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// A media file that exists, so it has a stamp. Nothing reads its contents —
  /// the analyser is faked — but the cache has to be able to stat it.
  MediaAsset media(String id, {int bytes = 4096}) {
    final file = File('${root.path}/$id.m4a')
      ..writeAsBytesSync(Uint8List(bytes));
    return MediaAsset(
      id: id,
      path: file.path,
      displayName: '$id.m4a',
      probe: audioProbe(),
    );
  }

  NativePeaks song() => nativePyramid(steadyWithSpike(256, at: 100));

  test('a waveform is asked for once however often it is requested', () async {
    var calls = 0;
    final cache = WaveformCache(analyzer: (path) async {
      calls++;
      return song();
    });
    addTearDown(cache.dispose);

    final asset = media('a');
    // The timeline repaints on every transport tick; requesting from a paint
    // has to be free.
    for (var i = 0; i < 20; i++) {
      cache.request(asset);
    }
    await pumpUntil(() => cache.stateOf('a') == WaveformState.ready);

    expect(calls, 1);
    expect(cache.peaksOf('a'), isNotNull);
  });

  test('a silent file is answered without touching the engine', () async {
    var calls = 0;
    final cache = WaveformCache(analyzer: (path) async {
      calls++;
      return song();
    });
    addTearDown(cache.dispose);

    final silent = MediaAsset(
      id: 'shot',
      path: '${root.path}/shot.mp4',
      displayName: 'shot.mp4',
      probe: videoProbe(audio: false),
    );
    cache.request(silent);

    // The probe already said there is no sound in it; decoding a whole file to
    // find that out again would be a decode per silent clip, every launch.
    expect(calls, 0);
    expect(cache.stateOf('shot'), WaveformState.none);
  });

  test('a file the engine will not read is a clip without a waveform',
      () async {
    var calls = 0;
    final cache = WaveformCache(analyzer: (path) async {
      calls++;
      throw const EngineException('nope');
    });
    addTearDown(cache.dispose);

    final asset = media('bad');
    cache.request(asset);
    await pumpUntil(() => cache.stateOf('bad') == WaveformState.failed);

    expect(cache.peaksOf('bad'), isNull);

    // And it is not retried on the next paint: a codec that would not decode a
    // second ago will not decode this frame either, and a timeline that kept
    // asking would spend the session decoding.
    for (var i = 0; i < 10; i++) {
      cache.request(asset);
    }
    await pumpUntil(() => true);
    expect(calls, 1);
  });

  group('the peak file', () {
    test('is written once and read back instead of analysing again', () async {
      var first = 0;
      final writer = WaveformCache(
        directory: cacheDir,
        analyzer: (path) async {
          first++;
          return song();
        },
      );
      addTearDown(writer.dispose);

      final asset = media('bed');
      writer.request(asset);
      await pumpUntil(() => writer.stateOf('bed') == WaveformState.ready);
      expect(first, 1);
      expect(cacheDir.listSync().whereType<File>().length, 1);

      // A different session, the same machine, the same file.
      var second = 0;
      final reader = WaveformCache(
        directory: cacheDir,
        analyzer: (path) async {
          second++;
          return song();
        },
      );
      addTearDown(reader.dispose);

      reader.request(asset);
      await pumpUntil(() => reader.stateOf('bed') == WaveformState.ready);

      expect(second, 0, reason: 'analysed a file it had already analysed');
      expect(reader.peaksOf('bed'), writer.peaksOf('bed'));
    });

    test('is thrown away when the media changed underneath it', () async {
      var calls = 0;
      Future<NativePeaks?> analyze(String path) async {
        calls++;
        return song();
      }

      final first = WaveformCache(directory: cacheDir, analyzer: analyze);
      addTearDown(first.dispose);
      final asset = media('take');
      first.request(asset);
      await pumpUntil(() => first.stateOf('take') == WaveformState.ready);
      expect(calls, 1);

      // Re-exported, re-recorded, or relinked to a different file of the same
      // name. The waveform on screen has to be a waveform of what is there now.
      File(asset.path).writeAsBytesSync(Uint8List(9000));

      final second = WaveformCache(directory: cacheDir, analyzer: analyze);
      addTearDown(second.dispose);
      second.request(asset);
      await pumpUntil(() => second.stateOf('take') == WaveformState.ready);

      expect(calls, 2);
      // And the stale one did not accumulate beside the fresh one.
      expect(cacheDir.listSync().whereType<File>().length, 1);
    });

    test('a corrupt one costs an analysis and nothing else', () async {
      var calls = 0;
      Future<NativePeaks?> analyze(String path) async {
        calls++;
        return song();
      }

      final first = WaveformCache(directory: cacheDir, analyzer: analyze);
      addTearDown(first.dispose);
      final asset = media('sting');
      first.request(asset);
      await pumpUntil(() => first.stateOf('sting') == WaveformState.ready);

      // A crash mid-write, a truncated copy, a file from a version that no
      // longer exists — all the same to a cache.
      final peakFile = cacheDir.listSync().whereType<File>().single;
      peakFile.writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4, 5]));

      final second = WaveformCache(directory: cacheDir, analyzer: analyze);
      addTearDown(second.dispose);
      second.request(asset);
      await pumpUntil(() => second.stateOf('sting') == WaveformState.ready);

      expect(calls, 2);
      expect(second.peaksOf('sting'), isNotNull);
      // Rewritten, so the next session is fast again.
      expect(PeakFile.decode(peakFile.readAsBytesSync()).levelCount,
          greaterThan(1));
    });

    test('the directory is trimmed to its budget, oldest first', () async {
      cacheDir.createSync(recursive: true);
      final made = <File>[];
      for (var i = 0; i < 5; i++) {
        final file = File('${cacheDir.path}/f$i.vdpk')
          ..writeAsBytesSync(Uint8List(1000));
        file.setLastModifiedSync(
            DateTime(2026, 1, 1).add(Duration(days: i)));
        made.add(file);
      }
      // Something that is not ours is left alone: this sweeps a cache, it does
      // not clear a directory.
      final stranger = File('${cacheDir.path}/notes.txt')
        ..writeAsStringSync('leave me');

      final cache = WaveformCache(
        directory: cacheDir,
        maxBytesOnDisk: 2500,
        analyzer: (path) async => song(),
      );
      addTearDown(cache.dispose);
      await cache.prune();

      // Newest first until the budget runs out: f4, f3 kept; f2 tips over it
      // and everything older goes with it.
      expect(made[4].existsSync(), isTrue);
      expect(made[3].existsSync(), isTrue);
      expect(made[2].existsSync(), isFalse);
      expect(made[1].existsSync(), isFalse);
      expect(made[0].existsSync(), isFalse);
      expect(stranger.existsSync(), isTrue);
    });

    test('a project with no cache directory still draws waveforms', () async {
      var calls = 0;
      final cache = WaveformCache(analyzer: (path) async {
        calls++;
        return song();
      });
      addTearDown(cache.dispose);

      cache.request(media('x'));
      await pumpUntil(() => cache.stateOf('x') == WaveformState.ready);

      expect(calls, 1);
      expect(cache.peaksOf('x'), isNotNull);
    });
  });

  test('what is held in memory is bounded by bytes, not by files', () async {
    final cache = WaveformCache(
      // Room for one pyramid and not two.
      maxBytesInMemory: 600,
      analyzer: (path) async => nativePyramid(steadyWithSpike(64, at: 3)),
    );
    addTearDown(cache.dispose);

    cache.request(media('one'));
    await pumpUntil(() => cache.stateOf('one') == WaveformState.ready);
    cache.request(media('two'));
    await pumpUntil(() => cache.stateOf('two') == WaveformState.ready);

    expect(cache.peaksOf('two'), isNotNull);
    expect(cache.peaksOf('one'), isNull);
    // Forgotten rather than remembered as failed, so scrolling back to it asks
    // again instead of drawing a clip that will never get its waveform.
    expect(cache.stateOf('one'), WaveformState.unknown);
  });

  test('forgetting an asset asks for it again next time', () async {
    var calls = 0;
    final cache = WaveformCache(analyzer: (path) async {
      calls++;
      return song();
    });
    addTearDown(cache.dispose);

    final asset = media('relink');
    cache.request(asset);
    await pumpUntil(() => cache.stateOf('relink') == WaveformState.ready);

    cache.forget('relink');
    expect(cache.peaksOf('relink'), isNull);

    cache.request(asset);
    await pumpUntil(() => cache.stateOf('relink') == WaveformState.ready);
    expect(calls, 2);
  });
}
