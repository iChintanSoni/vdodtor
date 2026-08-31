import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/thumbnails.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import 'fakes.dart';

/// A 2x2 picture, which is all a cache test needs to be a real one.
NativeThumbnail tinyThumbnail() => NativeThumbnail(
      width: 2,
      height: 2,
      bgra: Uint8List.fromList(List<int>.filled(2 * 2 * 4, 0xFF)),
    );

MediaAsset asset(String id, {MediaProbe? probe}) => MediaAsset(
      id: id,
      path: '/f/$id.mp4',
      displayName: '$id.mp4',
      probe: probe ?? videoProbe(),
    );

void main() {
  test('a thumbnail is asked for once however often it is requested', () async {
    var calls = 0;
    final cache = ThumbnailCache(renderer: (path, ticks, size) async {
      calls++;
      return tinyThumbnail();
    });
    addTearDown(cache.dispose);

    final a = asset('a');
    // A bin row rebuilds constantly; requesting from build has to be free.
    for (var i = 0; i < 20; i++) {
      cache.request(a);
    }
    await pumpUntil(() => cache.stateOf('a') == ThumbnailState.ready);

    expect(calls, 1);
    expect(cache.imageOf('a'), isNotNull);
  });

  test('an audio asset is answered without touching the engine', () async {
    var calls = 0;
    final cache = ThumbnailCache(renderer: (path, ticks, size) async {
      calls++;
      return tinyThumbnail();
    });
    addTearDown(cache.dispose);

    cache.request(asset('song', probe: audioProbe()));

    // No picture to decode, and the probe already said so — decoding to find
    // out would be a decode per audio file in the bin, every launch.
    expect(calls, 0);
    expect(cache.stateOf('song'), ThumbnailState.none);
  });

  test('a file with no picture comes back as none, not as broken', () async {
    final cache = ThumbnailCache(renderer: (path, ticks, size) async => null);
    addTearDown(cache.dispose);

    cache.request(asset('a'));
    await pumpUntil(() => cache.stateOf('a') != ThumbnailState.pending);

    expect(cache.stateOf('a'), ThumbnailState.none);
    expect(cache.imageOf('a'), isNull);
  });

  test('a render that throws leaves a failed state, not an exception',
      () async {
    final cache = ThumbnailCache(
        renderer: (path, ticks, size) async =>
            throw const EngineException('could not open the file'));
    addTearDown(cache.dispose);

    cache.request(asset('a'));
    await pumpUntil(() => cache.stateOf('a') != ThumbnailState.pending);

    expect(cache.stateOf('a'), ThumbnailState.failed);
  });

  test('no more than `concurrency` decodes run at once', () async {
    var running = 0;
    var peak = 0;
    final gate = Completer<void>();
    final cache = ThumbnailCache(
      concurrency: 2,
      renderer: (path, ticks, size) async {
        running++;
        peak = running > peak ? running : peak;
        await gate.future;
        running--;
        return tinyThumbnail();
      },
    );
    addTearDown(cache.dispose);

    for (var i = 0; i < 8; i++) {
      cache.request(asset('a$i'));
    }
    await Future<void>.delayed(Duration.zero);
    expect(peak, 2);

    gate.complete();
    await pumpUntil(() => cache.stateOf('a7') == ThumbnailState.ready);
    expect(peak, 2);
  });

  test('the cache is bounded, and the oldest goes first', () async {
    final cache = ThumbnailCache(
      capacity: 2,
      renderer: (path, ticks, size) async => tinyThumbnail(),
    );
    addTearDown(cache.dispose);

    for (final id in ['a', 'b', 'c']) {
      cache.request(asset(id));
      await pumpUntil(() => cache.stateOf(id) == ThumbnailState.ready);
    }

    expect(cache.imageOf('a'), isNull);
    expect(cache.imageOf('b'), isNotNull);
    expect(cache.imageOf('c'), isNotNull);
  });

  test('notifies once a picture arrives', () async {
    var notifications = 0;
    final cache = ThumbnailCache(
        renderer: (path, ticks, size) async => tinyThumbnail());
    addTearDown(cache.dispose);
    cache.addListener(() => notifications++);

    cache.request(asset('a'));
    expect(notifications, 0); // nothing to repaint for yet
    await pumpUntil(() => cache.stateOf('a') == ThumbnailState.ready);
    expect(notifications, 1);
  });

  test('forgetting an asset makes the next request render again', () async {
    var calls = 0;
    final cache = ThumbnailCache(renderer: (path, ticks, size) async {
      calls++;
      return tinyThumbnail();
    });
    addTearDown(cache.dispose);

    cache.request(asset('a'));
    await pumpUntil(() => cache.stateOf('a') == ThumbnailState.ready);
    cache.forget('a');
    cache.request(asset('a'));
    await pumpUntil(() => cache.stateOf('a') == ThumbnailState.ready);

    expect(calls, 2);
  });

  group('which frame gets picked', () {
    test('one second in, for anything long enough', () {
      expect(thumbnailTick(videoProbe(seconds: 30)),
          Timebase.project.fromSeconds(Rational.one));
    });

    test('the midpoint of a clip shorter than two seconds', () {
      // A second into a 1.2-second clip is past the end; halfway is a frame
      // that exists.
      expect(thumbnailTick(videoProbe(seconds: 1.2)).raw,
          Timebase.project.fromSeconds(Rational(600, 1000)).raw);
    });

    test('the start of something with no duration at all', () {
      expect(thumbnailTick(imageProbe()), Tick.zero);
    });
  });
}
