import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/ui/export_dialog.dart';

import '../fixtures.dart';

/// Everything below the save panel is native — the encoder, the disk check —
/// so these tests stop at the panel. That is not a gap: the panel is where the
/// sheet stops deciding and starts doing, and what it decided is exactly what
/// is worth checking here. `vd_export_test.c` owns the rest.
void main() {
  const channel = MethodChannel('vdodtor/media_access');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      // Cancelled, which is the one answer that never reaches the engine.
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> openSheet(WidgetTester tester, Project project) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showExportDialog(context,
                  project: project, projectName: 'Holiday'),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('opens at the project size, and says what it will produce',
      (tester) async {
    await openSheet(tester, projectWithThreeClips());

    expect(find.text('Same as project'), findsOneWidget);
    // Six seconds at 30 fps of 1920x1080 H.264.
    expect(
      find.textContaining('1920 × 1080 · 6.2 Mbps · 180 frames · about'),
      findsOneWidget,
    );
  });

  testWidgets('choosing 4K changes the size it will write', (tester) async {
    await openSheet(tester, projectWithThreeClips());

    await tester.tap(find.text('4K'));
    await tester.pump();

    expect(find.textContaining('3840 × 2160 · 25 Mbps'), findsOneWidget);
  });

  testWidgets('a vertical project exported at 1080p stays vertical',
      (tester) async {
    final project = Project.empty(
      id: 'pr-v',
      name: 'Vertical',
      format: ProjectFormat.fromAspect(ProjectAspect.portrait9x16,
          frameRate: FrameRates.fps30),
      mainTrackId: mainTrackId,
      audioTrackId: audioTrackId,
    ).addMedia(videoAsset('m1'));
    final withClip = project.updateTrack(
      mainTrackId,
      (t) => t.withClips([
        clipOf('a', 'm1', start: Tick.zero, duration: secs(2)),
      ]),
    );

    await openSheet(tester, withClip);
    await tester.tap(find.text('1080p'));
    await tester.pump();

    expect(find.textContaining('1080 × 1920'), findsOneWidget);
  });

  testWidgets('HEVC promises a smaller file than H.264', (tester) async {
    await openSheet(tester, projectWithThreeClips());
    final before = _summary(tester);

    await tester.tap(find.text('HEVC'));
    await tester.pump();

    expect(_summary(tester), isNot(before));
    expect(_summary(tester), contains('3.7 Mbps'));
  });

  testWidgets('turning the sound off changes only the size', (tester) async {
    await openSheet(tester, projectWithThreeClips());
    final before = _summary(tester);

    await tester.tap(find.text('Include sound'));
    await tester.pump();

    final after = _summary(tester);
    expect(after, isNot(before));
    expect(after, contains('1920 × 1080 · 6.2 Mbps · 180 frames'));
  });

  testWidgets('an empty timeline says so and offers nothing to press',
      (tester) async {
    await openSheet(tester, emptyProject());

    expect(find.text('There is nothing on the timeline to export yet.'),
        findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('Export… asks where to put it, named after the project',
      (tester) async {
    await openSheet(tester, projectWithThreeClips());

    await tester.tap(find.text('Export…'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'saveFile');
    expect(calls.single.arguments['name'], 'Holiday.mp4');
    expect(calls.single.arguments['extension'], 'mp4');
  });

  testWidgets('cancelling the panel leaves the sheet exactly as it was',
      (tester) async {
    await openSheet(tester, projectWithThreeClips());
    await tester.tap(find.text('4K'));
    await tester.pump();

    await tester.tap(find.text('Export…'));
    await tester.pumpAndSettle();

    // Still the settings, still on 4K, and nothing said went wrong: cancelling
    // a panel is not a failure.
    expect(find.textContaining('3840 × 2160'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('Cancel closes a sheet nothing has started', (tester) async {
    await openSheet(tester, projectWithThreeClips());

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Export'), findsNothing);
  });
}

/// The one line that says what the choices add up to.
String _summary(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .firstWhere((text) => text.contains('frames · about'));
