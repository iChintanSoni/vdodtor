import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/about.dart';
import 'package:vdodtor/ui/about_dialog.dart';

/// What the About sheet shows. The facts inside the documents are
/// `test/app/about_test.dart`'s subject; this is about the sheet being able to
/// put them in front of somebody, which is the half of LGPL 2.1 §6 that a file
/// in a repository does not discharge.
void main() {
  const system = MethodChannel('vdodtor/system');
  final opened = <String>[];
  var linkWorks = true;

  setUp(() {
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
        .setMockMethodCallHandler(system, null);
  });

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

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showAboutSheet(context),
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
}
