import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/ui/shortcut_sheet.dart';
import 'package:vdodtor/ui/shortcuts.dart';


void main() {
  group('the table', () {
    test('every action is bound exactly once', () {
      final seen = <EditorAction>[];
      for (final spec in editorShortcuts) {
        seen.add(spec.action);
      }
      expect(seen.toSet(), EditorAction.values.toSet(),
          reason: 'an action with no row is a command with no way to reach it');
      expect(seen.length, seen.toSet().length,
          reason: 'two rows for one action is two answers to one question');
    });

    test('no chord reaches two actions', () {
      // The failure this catches is silent: `CallbackShortcuts` takes a map,
      // so a duplicate key does not conflict, it *overwrites* — and whichever
      // of the two was written second is the one that runs, for ever, without
      // anything saying so.
      // Keyed on the activator itself, which has value equality. Keyed on
      // what `describeChord` prints it would be wrong in both directions:
      // `-` and the numpad's `−` are one glyph and two different keys.
      final owner = <SingleActivator, EditorAction>{};
      for (final spec in editorShortcuts) {
        for (final key in spec.keys) {
          final previous = owner[key];
          expect(previous, isNull,
              reason: '${describeChord(key)} is on both ${previous?.name} '
                  'and ${spec.action.name}');
          owner[key] = spec.action;
        }
      }
    });

    test('every row has keys and something to call it', () {
      for (final spec in editorShortcuts) {
        expect(spec.keys, isNotEmpty, reason: '${spec.action.name} has no keys');
        expect(spec.label.trim(), isNotEmpty,
            reason: '${spec.action.name} has no label, so the sheet cannot '
                'list it and nobody can find it');
      }
    });
  });

  group('binding', () {
    test('expands synonyms onto the same callback', () {
      var calls = 0;
      final bindings = shortcutBindings({
        for (final action in EditorAction.values)
          action: () => action == EditorAction.zoomIn ? calls++ : null,
      });

      // ⌘= and ⌘+ are one intention typed on two keyboards.
      const plain = SingleActivator(LogicalKeyboardKey.equal, meta: true);
      const shifted =
          SingleActivator(LogicalKeyboardKey.equal, meta: true, shift: true);
      expect(bindings[plain], isNotNull);
      expect(bindings[shifted], isNotNull);
      bindings[plain]!();
      bindings[shifted]!();
      expect(calls, 2);
    });

    test('refuses to build with an action unhandled', () {
      // A shortcut wired to nothing is a key that does nothing when pressed,
      // which reads as a broken editor rather than as a missing case. Failing
      // to build the screen is the louder and therefore better outcome.
      final incomplete = {
        for (final action in EditorAction.values)
          if (action != EditorAction.zoomToFit) action: () {},
      };
      expect(() => shortcutBindings(incomplete), throwsStateError);
    });
  });

  group('chords read the way the machine writes them', () {
    test('modifiers come in Apple order', () {
      expect(
          describeChord(const SingleActivator(LogicalKeyboardKey.keyZ,
              meta: true, shift: true)),
          '⇧⌘Z');
      expect(
          describeChord(const SingleActivator(LogicalKeyboardKey.arrowLeft,
              alt: true)),
          '⌥←');
    });

    test('named keys get their names', () {
      expect(describeChord(const SingleActivator(LogicalKeyboardKey.space)),
          'Space');
      expect(describeChord(const SingleActivator(LogicalKeyboardKey.backspace)),
          '⌫');
      expect(
          describeChord(
              const SingleActivator(LogicalKeyboardKey.digit0, meta: true)),
          '⌘0');
    });
  });

  group('dispatch', () {
    /// Presses [chord] with its modifiers held, the way a person would.
    Future<void> press(WidgetTester tester, SingleActivator chord) async {
      final modifiers = <LogicalKeyboardKey>[
        if (chord.control) LogicalKeyboardKey.controlLeft,
        if (chord.alt) LogicalKeyboardKey.altLeft,
        if (chord.shift) LogicalKeyboardKey.shiftLeft,
        if (chord.meta) LogicalKeyboardKey.metaLeft,
      ];
      for (final key in modifiers) {
        await tester.sendKeyDownEvent(key);
      }
      await tester.sendKeyDownEvent(chord.trigger);
      await tester.sendKeyUpEvent(chord.trigger);
      for (final key in modifiers.reversed) {
        await tester.sendKeyUpEvent(key);
      }
      await tester.pump();
    }

    testWidgets('every chord in the table reaches its own action',
        (tester) async {
      // The table test above says no two rows *claim* the same chord. This
      // one says Flutter agrees: an activator can be well-formed, unique and
      // still never match, and the symptom is a key that does nothing.
      //
      // What it cannot say is which physical key produces which logical one
      // on a real keyboard — these events are synthetic. That part is the
      // owner's to press.
      final fired = <EditorAction>[];
      await tester.pumpWidget(MaterialApp(
        home: CallbackShortcuts(
          bindings: shortcutBindings({
            for (final action in EditorAction.values)
              action: () => fired.add(action),
          }),
          child: const Focus(autofocus: true, child: SizedBox.expand()),
        ),
      ));
      await tester.pump();

      for (final spec in editorShortcuts) {
        for (final chord in spec.keys) {
          fired.clear();
          await press(tester, chord);
          expect(fired, [spec.action],
              reason: '${describeChord(chord)} should reach '
                  '${spec.action.name}');
        }
      }
    });
  });

  group('the sheet', () {
    testWidgets('lists every shortcut under its heading', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ShortcutSheet()));

      // Scrolled to, not merely searched for: the list is longer than the
      // sheet and builds lazily, so a plain `find.text` would pass or fail on
      // where a row happens to land rather than on whether it is there.
      final list = find.byType(Scrollable);

      // Generated from the table, so this is the assertion that keeps the two
      // from drifting: add a row and it appears, with no second list to edit.
      for (final spec in editorShortcuts) {
          await tester.scrollUntilVisible(find.text(spec.label), 60,
            scrollable: list);
        expect(find.text(spec.label), findsOneWidget,
            reason: '${spec.action.name} is bound but not listed');
        expect(find.text(describeChord(spec.keys.first)), findsWidgets);
      }
      // Back up the list, and therefore in reverse order: the loop above
      // finished at the bottom, and scrolling up looking for a heading that is
      // still below would run to the end of its patience and report the
      // heading missing when it is merely the other way.
      for (final group in ShortcutGroup.values.reversed) {
        await tester.scrollUntilVisible(find.text(group.title), -60,
            scrollable: list);
        expect(find.text(group.title), findsOneWidget);
      }
    });
  });
}
