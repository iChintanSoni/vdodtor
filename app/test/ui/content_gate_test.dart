import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/commands/document_store.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/media/packs.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/pro/tier.dart';
import 'package:vdodtor/ui/inspector.dart';
import 'package:vdodtor/ui/theme.dart';
import 'package:vdodtor/ui/timeline/timeline_controller.dart';

import '../fixtures.dart';
import 'timeline/timeline_controller_test.dart' show FakeTransport;

/// Content goes nowhere: this file is about the picker, and a widget test has
/// no engine to register a `.cube` with.
final class _Nowhere implements ContentSink {
  const _Nowhere();

  @override
  void look(String name, Uint8List cube) {}

  @override
  void font(Uint8List data) {}
}

/// The gate that stands between a free installation and the content a pack
/// brought.
///
/// It is one rule and this file is the whole of its evidence: **a locked item
/// changes what may be chosen, never what is drawn.** The pack is loaded
/// before every test here — registered, present, and as far as the engine is
/// concerned indistinguishable from the free five.
void main() {
  late DocumentStore store;
  late TimelineController controller;

  setUp(() async {
    store = DocumentStore(projectWithThreeClips());
    controller = TimelineController(
      store: store,
      transport: FakeTransport(durationTicks: secs(6).raw),
      ids: IdGen.seeded(2),
    );
    // The pack the app ships, read out of the real bundle.
    await ContentPacks.load(sink: const _Nowhere());
  });

  tearDown(() {
    ContentPacks.reset();
    controller.dispose();
    store.dispose();
  });

  var offered = 0;

  Future<void> pump(WidgetTester tester, {Tier tier = Tier.free}) {
    offered = 0;
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => Inspector(
              timeline: controller,
              tier: tier,
              onGetPro: () => offered++,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openLooks(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('COLOUR'), 120,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
  }

  /// The Cinema pack's first look, taken from the catalogue rather than
  /// spelled out, so renaming one in `tools/make_luts.dart` does not need a
  /// matching edit here.
  String lockedLook() =>
      ContentPacks.looks.firstWhere((l) => l.isLocked).name;

  group('a free installation', () {
    testWidgets('is offered the locked looks, wearing a badge', (tester) async {
      controller.select('b');
      await pump(tester);
      await openLooks(tester);

      // Listed rather than hidden, which is the export sheet's decision about
      // a locked size applied to content: somebody deciding whether to buy Pro
      // should be able to see what is in it.
      expect(find.text(lockedLook()), findsWidgets);
      expect(find.byType(ProBadge), findsWidgets);
    });

    testWidgets('choosing one opens the sheet instead of grading',
        (tester) async {
      controller.select('b');
      await pump(tester);
      await openLooks(tester);

      await tester.tap(find.text(lockedLook()).last);
      await tester.pumpAndSettle();

      expect(offered, 1);
      expect(store.project.clipById('b')!.color.look, isEmpty);
      expect(store.canUndo, isFalse, reason: 'a refusal is not an edit');
    });

    testWidgets('can still choose a free one', (tester) async {
      controller.select('b');
      await pump(tester);
      await openLooks(tester);

      await tester.tap(find.text('Noir').last);
      await tester.pumpAndSettle();

      expect(store.project.clipById('b')!.color.look, 'Noir');
      expect(offered, 0);
    });

    // The whole rule, at the only place it can be checked from outside: a
    // document that already names a locked look keeps it, shows it, and is not
    // quietly reset by opening the panel.
    testWidgets('does not take a locked look off a clip that has one',
        (tester) async {
      final locked = lockedLook();
      store.run(SetClipColor('b', ClipColor(look: locked)));
      store.endGesture();
      controller.select('b');

      await pump(tester);
      await tester.scrollUntilVisible(find.text('COLOUR'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(store.project.clipById('b')!.color.look, locked);
      expect(find.text(locked), findsWidgets);
      // And the strength slider is there, because the look is on the clip and
      // being drawn.
      expect(find.text('Strength'), findsOneWidget);
    });
  });

  group('Pro', () {
    testWidgets('is offered the same list with no badge on it', (tester) async {
      controller.select('b');
      await pump(tester, tier: Tier.pro);
      await openLooks(tester);

      expect(find.text(lockedLook()), findsWidgets);
      expect(find.byType(ProBadge), findsNothing);
    });

    testWidgets('can put a pack look on a clip', (tester) async {
      final locked = lockedLook();
      controller.select('b');
      await pump(tester, tier: Tier.pro);
      await openLooks(tester);

      await tester.tap(find.text(locked).last);
      await tester.pumpAndSettle();

      expect(store.project.clipById('b')!.color.look, locked);
      expect(store.project.clipById('b')!.color.lookStrength, 1);
      expect(offered, 0);
    });
  });

  // No pack sells a typeface yet, so the font picker's gate has nothing to
  // stop — which is the assertion: a free installation sees every face it
  // always saw, with nothing new in front of it.
  testWidgets('the font picker gates nothing it should not', (tester) async {
    controller.addTextClip();
    await pump(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();

    expect(find.byType(ProBadge), findsNothing);
    for (final face in ContentPacks.faces) {
      expect(face.isLocked, isFalse, reason: face.name);
    }
  });
}
