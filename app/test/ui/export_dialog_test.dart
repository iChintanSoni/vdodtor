import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/pro/entitlement.dart';
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

  Future<Entitlement> openSheet(
    WidgetTester tester,
    Project project, {
    Tier tier = Tier.free,
  }) async {
    final entitlement = Entitlement(tier);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showExportDialog(context,
                  project: project,
                  projectName: 'Holiday',
                  entitlement: entitlement),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return entitlement;
  }

  /// A project cut at 4K, so that the project's *own* size is the locked one.
  Project uhdProject() => Project.empty(
        id: 'pr-uhd',
        name: 'Big',
        format: const ProjectFormat(
            width: 3840, height: 2160, frameRate: FrameRates.fps30),
        mainTrackId: mainTrackId,
        audioTrackId: audioTrackId,
      ).addMedia(videoAsset('m1')).updateTrack(
            mainTrackId,
            (t) => t.withClips([
              clipOf('a', 'm1', start: Tick.zero, duration: secs(2)),
            ]),
          );

  bool exportEnabled(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed != null;

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

    await tester.tap(find.widgetWithText(ChoiceChip, '4K'));
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
    await tester.tap(find.widgetWithText(ChoiceChip, '1080p'));
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
    await openSheet(tester, projectWithThreeClips(), tier: Tier.pro);
    await tester.tap(find.widgetWithText(ChoiceChip, '4K'));
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

  group('the Pro gate', () {
    testWidgets('4K wears a badge for a free installation', (tester) async {
      await openSheet(tester, projectWithThreeClips());

      expect(find.text('PRO'), findsOneWidget);
      expect(
          find.descendant(
              of: find.widgetWithText(ChoiceChip, '4K'),
              matching: find.text('PRO')),
          findsOneWidget);
    });

    testWidgets('and none of them wears one for Pro', (tester) async {
      await openSheet(tester, projectWithThreeClips(), tier: Tier.pro);

      expect(find.text('PRO'), findsNothing);
    });

    testWidgets('a locked size shows what it would produce, and will not write '
        'it', (tester) async {
      await openSheet(tester, projectWithThreeClips());
      expect(exportEnabled(tester), isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, '4K'));
      await tester.pump();

      // The numbers are real — somebody deciding whether to buy Pro can see
      // exactly what they would get.
      expect(_summary(tester), contains('3840 × 2160 · 25 Mbps'));
      expect(find.textContaining('is part of vdodtor Pro'), findsOneWidget);
      expect(exportEnabled(tester), isFalse);
    });

    testWidgets('the gate says what is not locked', (tester) async {
      // The sentence that matters most in a product positioned against the
      // watermark-and-upsell editors.
      await openSheet(tester, projectWithThreeClips());
      await tester.tap(find.widgetWithText(ChoiceChip, '4K'));
      await tester.pump();

      expect(find.textContaining('no watermark on anything, ever'),
          findsOneWidget);
    });

    testWidgets('pressing a locked Export writes nothing and asks nothing',
        (tester) async {
      await openSheet(tester, projectWithThreeClips());
      await tester.tap(find.widgetWithText(ChoiceChip, '4K'));
      await tester.pump();

      await tester.tap(find.text('Export…'));
      await tester.pumpAndSettle();

      // Not even the save panel: the refusal happens before anything is
      // chosen, so there is no half-started export to tidy up.
      expect(calls, isEmpty);
    });

    testWidgets('Pro writes 4K, and is asked where to put it', (tester) async {
      await openSheet(tester, projectWithThreeClips(), tier: Tier.pro);
      await tester.tap(find.widgetWithText(ChoiceChip, '4K'));
      await tester.pump();

      expect(find.textContaining('is part of vdodtor Pro'), findsNothing);
      expect(exportEnabled(tester), isTrue);

      await tester.tap(find.text('Export…'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
    });

    testWidgets('a free sheet on a 4K project opens on something it can write',
        (tester) async {
      await openSheet(tester, uhdProject());

      // Not a locked button as the first thing anybody sees, and nothing
      // silently substituted either: the line says the size that will be
      // written, and the project's own size is one chip away wearing a badge.
      expect(_summary(tester), contains('1920 × 1080'));
      expect(exportEnabled(tester), isTrue);
      // Both the project's own size and 4K are out of reach here.
      expect(find.text('PRO'), findsNWidgets(2));

      await tester.tap(find.widgetWithText(ChoiceChip, 'Same as project'));
      await tester.pump();
      expect(_summary(tester), contains('3840 × 2160'));
      expect(exportEnabled(tester), isFalse);
    });

    testWidgets('buying Pro lifts the gate under the open sheet',
        (tester) async {
      final entitlement = await openSheet(tester, projectWithThreeClips());
      await tester.tap(find.widgetWithText(ChoiceChip, '4K'));
      await tester.pump();
      expect(exportEnabled(tester), isFalse);

      // Which is the point of the sheet listening rather than reading a tier
      // once: it is this sheet that told them they needed Pro.
      entitlement.grant(Tier.pro);
      await tester.pump();

      expect(exportEnabled(tester), isTrue);
      expect(find.textContaining('is part of vdodtor Pro'), findsNothing);
      expect(find.text('PRO'), findsNothing);
      // And still 4K: unlocking must not move what they had chosen.
      expect(_summary(tester), contains('3840 × 2160'));
    });
  });
}

/// The one line that says what the choices add up to.
String _summary(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .firstWhere((text) => text.contains('frames · about'));
