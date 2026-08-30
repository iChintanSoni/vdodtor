import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/thumbnails.dart';
import 'package:vdodtor/model/media.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/ui/media_bin.dart';

import '../media/fakes.dart';

void main() {
  late ThumbnailCache thumbnails;

  setUp(() {
    // Never resolves: the bin has to be readable while its pictures are still
    // being decoded, which is most of the first second after a big import.
    thumbnails = ThumbnailCache(
        renderer: (path, ticks, size) => Future.any([]));
  });
  tearDown(() => thumbnails.dispose());

  MediaAsset asset(String id, {MediaProbe? probe, String? name}) => MediaAsset(
        id: id,
        path: '/footage/$id.mp4',
        displayName: name ?? '$id.mp4',
        probe: probe ?? videoProbe(seconds: 12),
      );

  Future<void> pumpBin(
    WidgetTester tester,
    List<MediaAsset> assets, {
    Set<String> unreachable = const {},
    bool busy = false,
    void Function(MediaAsset)? onPlace,
    void Function(MediaAsset)? onRemove,
    VoidCallback? onImport,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            MediaBin(
              assets: assets,
              thumbnails: thumbnails,
              unreachable: unreachable,
              busy: busy,
              onImport: onImport ?? () {},
              onPlace: onPlace ?? (_) {},
              onRemove: onRemove ?? (_) {},
            ),
          ]),
        ),
      ));

  testWidgets('an empty bin says how to fill it', (tester) async {
    await pumpBin(tester, const []);

    expect(find.textContaining('Drop footage'), findsOneWidget);
    expect(find.textContaining('⌘I'), findsOneWidget);
  });

  testWidgets('lists what is in the project, with duration and size',
      (tester) async {
    await pumpBin(tester, [asset('a'), asset('b')]);

    expect(find.text('a.mp4'), findsOneWidget);
    expect(find.text('b.mp4'), findsOneWidget);
    expect(find.text('0:12 · 1920×1080'), findsNWidgets(2));
    expect(find.text('2'), findsOneWidget); // the count in the header
  });

  testWidgets('an audio asset says so instead of pretending to have a size',
      (tester) async {
    await pumpBin(tester, [asset('song', probe: audioProbe(seconds: 95))]);

    expect(find.text('1:35 · audio'), findsOneWidget);
  });

  testWidgets('a missing file is listed, greyed, and marked', (tester) async {
    await pumpBin(tester, [asset('gone')], unreachable: {'gone'});

    // Still there — an asset the user has to point at again is worth keeping.
    expect(find.text('gone.mp4'), findsOneWidget);
    expect(find.text('File not found'), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  testWidgets('double-clicking an asset places it on the timeline',
      (tester) async {
    MediaAsset? placed;
    await pumpBin(tester, [asset('a')], onPlace: (a) => placed = a);

    await tester.tap(find.text('a.mp4'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('a.mp4'));
    await tester.pumpAndSettle();

    expect(placed?.id, 'a');
  });

  testWidgets('a missing asset cannot be placed', (tester) async {
    var placements = 0;
    await pumpBin(tester, [asset('gone')],
        unreachable: {'gone'}, onPlace: (_) => placements++);

    await tester.tap(find.text('gone.mp4'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('gone.mp4'));
    await tester.pumpAndSettle();

    expect(placements, 0);
  });

  testWidgets('the remove button appears on hover and removes that asset',
      (tester) async {
    MediaAsset? removed;
    await pumpBin(tester, [asset('a'), asset('b')],
        onRemove: (a) => removed = a);

    // Nothing to click until the pointer is over the row: a permanent × on
    // every row is a permanent invitation to lose media by accident.
    expect(find.byIcon(Icons.close), findsNothing);

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.text('b.mp4'))));
    await tester.pump();

    expect(find.byIcon(Icons.close), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(removed?.id, 'b');
  });

  testWidgets('the header offers import, and says when one is running',
      (tester) async {
    var imports = 0;
    await pumpBin(tester, const [], onImport: () => imports++);

    await tester.tap(find.byIcon(Icons.add));
    expect(imports, 1);

    await pumpBin(tester, const [], busy: true);
    // A drop that is still probing has to look like something is happening,
    // or it looks like the drop was ignored.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  group('shortDuration', () {
    test('reads like a duration, not a timecode', () {
      Tick at(int seconds) =>
          Timebase.project.fromSeconds(Rational(seconds, 1));
      expect(shortDuration(at(0)), '0:00');
      expect(shortDuration(at(9)), '0:09');
      expect(shortDuration(at(95)), '1:35');
      expect(shortDuration(at(3600)), '1:00:00');
      expect(shortDuration(at(3725)), '1:02:05');
    });
  });
}
