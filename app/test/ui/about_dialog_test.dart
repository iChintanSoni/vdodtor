import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/about.dart';
import 'package:vdodtor/app/crash.dart';
import 'package:vdodtor/ui/about_dialog.dart';

/// What the About sheet shows. The facts inside the documents are
/// `test/app/about_test.dart`'s subject; this is about the sheet being able to
/// put them in front of somebody, which is the half of LGPL 2.1 §6 that a file
/// in a repository does not discharge.
void main() {
  const system = MethodChannel('vdodtor/system');
  final opened = <String>[];
  var linkWorks = true;
  final copied = <String>[];
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('vdodtor_about_');
    copied.clear();
    // The Copy button is the only route a report takes off this machine, so
    // what it puts on the clipboard is worth asserting rather than assuming.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    // `rootBundle` caches the *future* it hands back, and `testWidgets` runs
    // each body in its own zone — so a second test awaiting a future created
    // in the first one's zone waits forever, and the sheet sits on "Reading…".
    // Nothing in the app can hit this; it is a hazard of one bundle outliving
    // many zones, and one line to remove.
    rootBundle.clear();
    opened.clear();
    linkWorks = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(system, (call) async {
      opened.add((call.arguments as Map)['url'] as String);
      return linkWorks;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(system, null)
      ..setMockMethodCallHandler(SystemChannels.platform, null);
    home.deleteSync(recursive: true);
  });

  /// A reporter with [faults] reports already on disk, as a relaunch would
  /// find them.
  CrashReporter reporterWith(int faults) {
    var second = 0;
    final reporter = CrashReporter(
      clock: () => DateTime.utc(2026, 9, 2, 14, 30, second++),
    )..attach(Directory('${home.path}/Reports')..createSync());
    for (var i = 0; i < faults; i++) {
      reporter.record(
        StateError('fault $i at /Users/ada/Movies/holiday.mov'),
        null,
        context: 'while building a widget',
      );
    }
    return reporter;
  }

  /// Lets the bundle read the sheet starts actually finish.
  ///
  /// `rootBundle` reaches a real file, which completes on the real event loop
  /// and resumes on the tester's fake one — so the two have to be alternated,
  /// exactly as `test/ui/start_screen_test.dart` does for the project library.
  /// `pumpAndSettle` alone would sit on the placeholder forever.
  Future<void> settleIo(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  }

  /// What the document box is showing.
  ///
  /// Reached through the scroll view rather than by type: the version line is
  /// selectable too, so a bug report can be typed out of it, and
  /// `find.byType(SelectableText)` alone now matches two things.
  String readerText(WidgetTester tester) => tester
      .widget<SelectableText>(find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(SelectableText),
      ))
      .data!;

  Future<void> openSheet(
    WidgetTester tester, {
    CrashReporter? reports,
    AboutTab initial = AboutTab.notices,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  showAboutSheet(context, reports: reports, initial: initial),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await settleIo(tester);
  }

  testWidgets('says which build this is', (tester) async {
    await openSheet(tester);
    expect(
      find.text('Version ${About.version} · ${About.copyright}'),
      findsOneWidget,
    );
  });

  testWidgets('opens on the notices, with the library named', (tester) async {
    await openSheet(tester);

    final reader = readerText(tester);
    expect(reader, contains('FFmpeg'));
    expect(reader, contains('Lesser General Public Licence'));
    // The written offer is the part somebody has to be able to read and copy.
    expect(reader, contains(About.source.toString()));
  });

  testWidgets('shows the licence itself when asked', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('LGPL 2.1'));
    await settleIo(tester);

    final reader = readerText(tester);
    expect(reader, contains('GNU LESSER GENERAL PUBLIC LICENSE'));
    expect(reader, contains('Version 2.1, February 1999'));
  });

  testWidgets('goes back to the notices', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('LGPL 2.1'));
    await settleIo(tester);
    await tester.tap(find.text('Third-party notices'));
    await settleIo(tester);

    final reader = readerText(tester);
    expect(reader, contains('FFmpeg'));
  });

  testWidgets('the source button opens the page we own', (tester) async {
    await openSheet(tester);
    await tester.tap(find.text('Get the source'));
    await settleIo(tester);

    expect(opened, [About.source.toString()]);
  });

  testWidgets('checking for updates opens the browser, not a socket',
      (tester) async {
    // The whole of the update mechanism. The app has no network entitlement,
    // so the asking is done by something that has one — see About.download.
    await openSheet(tester);
    await tester.tap(find.text('Check for updates…'));
    await settleIo(tester);

    expect(opened, [About.download.toString()]);
  });

  testWidgets('and says so, rather than leaving silence to be read as a bug',
      (tester) async {
    // An app that never mentions a new version is unusual enough that saying
    // nothing reads as an updater that is broken.
    await openSheet(tester);
    expect(find.textContaining('never checks for updates'), findsOneWidget);
  });

  testWidgets('and says where it is when it will not open', (tester) async {
    linkWorks = false;
    await openSheet(tester);
    await tester.tap(find.text('Get the source'));
    await settleIo(tester);

    // A button that silently does nothing is the one failure a user cannot
    // report — and here the address is the whole obligation, so printing it is
    // a working fallback rather than an apology.
    expect(
      find.textContaining(About.source.toString(), findRichText: true),
      findsWidgets,
    );
  });

  group('problem reports', () {
    testWidgets('are not a tab when there are none', (tester) async {
      // A permanently empty tab labelled "Problem reports" is furniture that
      // makes the app look like it expects to crash.
      await openSheet(tester, reports: reporterWith(0));
      expect(find.text('Problem reports'), findsNothing);
    });

    testWidgets('open straight onto the report when the banner asks',
        (tester) async {
      await openSheet(tester,
          reports: reporterWith(1), initial: AboutTab.reports);

      final reader = readerText(tester);
      expect(reader, contains('vdodtor problem report'));
      expect(reader, contains('fault 0'));
      expect(reader, contains('while building a widget'));
      // Redacted on the way to the disk, so redacted here by construction.
      expect(reader, isNot(contains('/Users/ada')));
    });

    testWidgets('say they were not collected, before they are read',
        (tester) async {
      // Without this line, a crash log inside an editor whose pitch is "your
      // footage never leaves this machine" reads as the thing the pitch said
      // was not happening.
      await openSheet(tester,
          reports: reporterWith(1), initial: AboutTab.reports);

      expect(find.textContaining('sent nowhere'), findsWidgets);
      expect(find.textContaining('Console'), findsOneWidget,
          reason: 'a crash in the engine itself is not in here, and the sheet '
              'has to say where that one lives');
    });

    testWidgets('are reachable from the tab strip after the banner is gone',
        (tester) async {
      // The banner is dismissed once; the report has to stay findable, and
      // this is the sheet that already means "this installation".
      final reports = reporterWith(2)..markSeen();
      await openSheet(tester, reports: reports);

      await tester.tap(find.text('Problem reports'));
      await tester.pump();

      final reader = readerText(tester);
      expect(reader, contains('fault 1'));
      expect(reader, contains('fault 0'));
      expect(reader.indexOf('fault 1'), lessThan(reader.indexOf('fault 0')),
          reason: 'newest first');
    });

    testWidgets('stop being offered once they have been shown',
        (tester) async {
      // Opening the sheet *is* being shown the report. Leaving the offer up
      // afterwards would make Dismiss the only way to clear a banner the user
      // has already acted on.
      final reports = reporterWith(1);
      expect(reports.hasUnseen, isTrue);

      await openSheet(tester, reports: reports, initial: AboutTab.reports);
      expect(reports.hasUnseen, isFalse);
    });

    testWidgets('copy exactly what is on screen', (tester) async {
      // The clipboard is the only route a report takes off this machine, and
      // what is copied has to be what was read — a report scrubbed on screen
      // and copied raw would be worse than no scrubbing at all.
      final reports = reporterWith(1);
      await openSheet(tester, reports: reports, initial: AboutTab.reports);

      await tester.tap(find.text('Copy'));
      await tester.pump();

      expect(copied, [readerText(tester)]);
      expect(copied.single, isNot(contains('/Users/ada')));
    });

    testWidgets('can be thrown away, and the tab goes with them',
        (tester) async {
      final reports = reporterWith(2);
      await openSheet(tester, reports: reports, initial: AboutTab.reports);

      await tester.tap(find.text('Delete'));
      await settleIo(tester);

      expect(reports.count, 0);
      expect(find.text('Problem reports'), findsNothing);
      // And the sheet is still open on something, rather than on an empty box.
      expect(readerText(tester), contains('FFmpeg'));
    });

    testWidgets('send somebody to the bug page in the browser', (tester) async {
      await openSheet(tester,
          reports: reporterWith(1), initial: AboutTab.reports);
      await tester.tap(find.text('Report a bug…'));
      await settleIo(tester);

      expect(opened, [About.bugs.toString()]);
    });

    testWidgets('fall back rather than showing an empty box', (tester) async {
      // The banner that asks for this tab and the deletion that emptied it can
      // happen in either order.
      await openSheet(tester, initial: AboutTab.reports);
      expect(readerText(tester), contains('FFmpeg'));
    });
  });
}
