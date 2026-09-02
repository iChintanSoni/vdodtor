import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/crash.dart';

/// What a problem report says, what it deliberately does not say, and what
/// happens to it afterwards.
///
/// The subject here is a privacy promise rather than a feature. vdodtor has no
/// network entitlement, so a report cannot be uploaded and the whole design
/// follows from that — but "cannot be uploaded" is not the same as "safe to
/// paste", and the part this file actually holds is the redaction: a stack
/// trace is full of absolute paths, and an absolute path carries the user's
/// account name, their folder layout and the names of their footage. That is
/// the one thing in the app that could carry somebody's private information
/// out of it, and it goes through one function that can be given a table.
void main() {
  late Directory home;
  late Directory reports;

  setUp(() {
    home = Directory.systemTemp.createTempSync('vdodtor_crash_');
    reports = Directory('${home.path}/Reports')..createSync(recursive: true);
  });
  tearDown(() => home.deleteSync(recursive: true));

  /// A clock that moves, so consecutive reports get consecutive file names.
  DateTime Function() ticking([int from = 0]) {
    var second = from;
    return () => DateTime.utc(2026, 9, 2, 14, 30, second++);
  }

  group('redaction', () {
    // One table, read left to right: what an error handler was handed, and
    // what is allowed to reach the disk. Every row that keeps something is as
    // load-bearing as every row that removes something — a redactor that ate
    // the stack trace would be perfectly private and perfectly useless.
    const table = <(String, String)>[
      // The whole point: the home directory and everything under it.
      (
        "PathNotFoundException: '/Users/ada/Movies/holiday.mov'",
        "PathNotFoundException: '<path>.mov'",
      ),
      // The same path as a stack frame writes it.
      (
        '#1 main (file:///Users/ada/src/app/lib/main.dart:12:5)',
        '#1 main (<path>)',
      ),
      // A directory has no extension to keep, so nothing is kept.
      ('failed under /Users/ada/Movies', 'failed under <path>'),
      // Kept: a package URI is where the bug is, and it names our source
      // rather than anybody's disk. This is the row that breaks first if the
      // pattern is loosened to "anything with a slash in it".
      (
        '#0 Timeline.build (package:vdodtor/ui/timeline/timeline_view.dart:88)',
        '#0 Timeline.build (package:vdodtor/ui/timeline/timeline_view.dart:88)',
      ),
      // Kept for the same reason, one layer down.
      (
        '#2 _rootRun (dart:async/zone.dart:1391:47)',
        '#2 _rootRun (dart:async/zone.dart:1391:47)',
      ),
      // Kept: an address the app itself wrote down. The slash after the
      // scheme is preceded by a letter, so it is not the start of a path.
      ('could not open https://vdodtor.app/pro', 'could not open '
          'https://vdodtor.app/pro'),
      // Not a path. A divide in a message is not a leak and must not read as
      // one, or every arithmetic error comes out unreadable.
      ('expected 3 / 4 of a frame', 'expected 3 / 4 of a frame'),
      // Two on one line, and the comma in between survives.
      (
        'copying /Users/ada/a.mov, /Users/ada/b.wav',
        'copying <path>.mov, <path>.wav',
      ),
      // An "extension" that is really the rest of a stack frame would say
      // where in somebody's home directory the file was, so it goes too.
      ('at /Users/ada/x.dart:118:7', 'at <path>'),
      // A path at the very start of a line, where there is no character in
      // front of it to match on.
      ('/Users/ada/Desktop/clip.mp4 is missing', '<path>.mp4 is missing'),
    ];

    for (final (input, expected) in table) {
      test('"$input"', () => expect(CrashReport.redact(input), expected));
    }

    test('runs before anything is written, not before anything is shown', () {
      // The distinction is the whole of the promise: an unredacted report that
      // is scrubbed on its way to the screen still leaves the original sitting
      // on the disk for something later to find.
      final reporter = CrashReporter(clock: ticking())..attach(reports);
      reporter.record(
        const FileSystemException('no', '/Users/ada/Movies/holiday.mov'),
        StackTrace.fromString('#0 x (file:///Users/ada/src/main.dart:1:1)'),
        context: 'while importing',
      );

      final written = reports
          .listSync()
          .whereType<File>()
          .single
          .readAsStringSync();
      expect(written, isNot(contains('/Users/ada')));
      expect(written, isNot(contains('holiday')));
      expect(written, contains('<path>.mov'));
    });
  });

  group('a report', () {
    test('says what it is, what build it came from, and what was happening',
        () {
      final report = CrashReport.of(
        StateError('the compositor said no'),
        StackTrace.fromString('#0 render (package:vdodtor/engine/x.dart:3:1)'),
        context: 'while building a widget',
        when: DateTime.utc(2026, 9, 2, 14, 30, 5),
        version: '1.2.3',
        system: 'macos Version 15.0 · Dart 3.9.0',
      );

      // The first line travels with the paste, into a bug tracker where none
      // of this file's context is around it.
      expect(report.text, startsWith('vdodtor problem report'));
      expect(report.text, contains('sent nowhere'));

      expect(report.text, contains('version   1.2.3'));
      expect(report.text, contains('when      2026-09-02T14:30:05.000Z'));
      expect(report.text, contains('system    macos Version 15.0 · Dart 3.9.0'));
      expect(report.text, contains('context   while building a widget'));
      expect(report.text, contains('the compositor said no'));
      expect(report.text, contains('package:vdodtor/engine/x.dart'));
    });

    test('says nothing about the machine that identifies anybody', () {
      // Not a spelling check on [CrashReport.describeSystem] — a check that
      // what it returns is a description of a *platform*. A hostname is the
      // one thing macOS will hand over that names a person, and it is usually
      // literally their name.
      final system = CrashReport.describeSystem();
      expect(system, contains(Platform.operatingSystem));
      expect(system.toLowerCase(), isNot(contains(Platform.localHostname
          .toLowerCase()
          .replaceAll('.local', ''))));
    });

    test('is named so that the directory sorts newest last', () {
      // What lets the store find the newest report by sorting names instead of
      // reading ten files and comparing timestamps inside them.
      String nameAt(int second) => CrashReport(
            when: DateTime.utc(2026, 9, 2, 14, 30, second),
            context: '',
            summary: '',
            stack: '',
            version: '1.0.0',
            system: '',
          ).fileName;

      final names = [nameAt(5), nameAt(9), nameAt(11)];
      expect(names, orderedEquals([...names]..sort()));
      expect(names.first, 'crash-2026-09-02T14-30-05Z.txt');
      expect(names.every((n) => n.contains(':')), isFalse,
          reason: 'a colon is legal in a Mac filename and awful everywhere '
              'a path gets pasted');
    });
  });

  group('the reporter', () {
    test('keeps faults that happen before storage is reachable', () {
      // The launch-time fault is the one nobody can reproduce, and it happens
      // before there is anywhere to write it. Dropping those would leave the
      // reporter useless in exactly the case it is for.
      final reporter = CrashReporter(clock: ticking());
      reporter.record(StateError('too early'), null, context: 'at launch');
      expect(reports.listSync(), isEmpty);

      reporter.attach(reports);
      expect(reporter.count, 1);
      expect(reporter.text, contains('too early'));
    });

    test('lists newest first and prunes to the last few', () {
      final reporter = CrashReporter(clock: ticking(), keep: 3)
        ..attach(reports);
      for (var i = 0; i < 5; i++) {
        reporter.record(StateError('fault $i'), null, context: 'x');
      }

      expect(reporter.count, 3);
      // The three that are kept are the three most recent, and the newest is
      // the one at the top of the document.
      expect(reporter.text.indexOf('fault 4'),
          lessThan(reporter.text.indexOf('fault 2')));
      expect(reporter.text, isNot(contains('fault 0')));
      expect(reporter.text, isNot(contains('fault 1')));
    });

    test('two faults in the same second are two reports', () {
      // A repeating fault is usually the *second* one; the first is what
      // started it, and overwriting it would lose the useful half.
      final reporter = CrashReporter(clock: () => DateTime.utc(2026, 9, 2))
        ..attach(reports);
      reporter.record(StateError('first'), null, context: 'x');
      reporter.record(StateError('second'), null, context: 'x');

      expect(reporter.count, 2);
      expect(reporter.text, contains('first'));
      expect(reporter.text, contains('second'));
    });

    test('offers a report once, and remembers that across a relaunch', () {
      final first = CrashReporter(clock: ticking())..attach(reports);
      expect(first.hasUnseen, isFalse);

      first.record(StateError('boom'), null, context: 'x');
      expect(first.hasUnseen, isTrue);
      first.markSeen();
      expect(first.hasUnseen, isFalse);

      // A different run of the app, same disk. The marker is on it, so the
      // banner does not come back for a report already read.
      final second = CrashReporter(clock: ticking(30))..attach(reports);
      expect(second.hasUnseen, isFalse);
      expect(second.count, 1, reason: 'dismissing an offer is not asking for '
          'the evidence to be destroyed');

      second.record(StateError('again'), null, context: 'x');
      expect(second.hasUnseen, isTrue);
    });

    test('deletes the lot when asked, marker included', () {
      final reporter = CrashReporter(clock: ticking())..attach(reports);
      reporter.record(StateError('boom'), null, context: 'x');
      reporter.markSeen();

      reporter.deleteAll();
      expect(reporter.count, 0);
      expect(reporter.text, isEmpty);
      expect(reports.listSync(), isEmpty,
          reason: 'the seen marker is app state about reports that no longer '
              'exist, and leaving it would suppress the next offer');
    });

    test('notifies when the offer changes and never when a fault arrives', () {
      // [record] runs inside `FlutterError.onError`, which fires in the middle
      // of build, layout or paint. Scheduling a repaint from there stacks a
      // second failure on the first one, so the banner is a launch-time fact.
      var notifications = 0;
      final reporter = CrashReporter(clock: ticking())
        ..attach(reports)
        ..addListener(() => notifications++);

      reporter.record(StateError('boom'), null, context: 'x');
      expect(notifications, 0);

      reporter.markSeen();
      expect(notifications, 1);
      reporter.deleteAll();
      expect(notifications, 2);
    });

    test('survives its own directory disappearing', () {
      // A reporter that can throw turns one bug into two, and the second one
      // arrives inside the handler for the first.
      final reporter = CrashReporter(clock: ticking())..attach(reports);
      reports.deleteSync(recursive: true);

      expect(() => reporter.record(StateError('boom'), null, context: 'x'),
          returnsNormally);
      expect(reporter.count, 0);
      expect(reporter.hasUnseen, isFalse);
      expect(() => reporter.markSeen(), returnsNormally);
      expect(() => reporter.deleteAll(), returnsNormally);
    });
  });

  group('the handlers', () {
    late FlutterExceptionHandler? previousOnError;

    setUp(() => previousOnError = FlutterError.onError);
    tearDown(() => FlutterError.onError = previousOnError);

    test('record a framework error without swallowing it', () {
      // Chaining rather than replacing is what makes this safe to install in
      // `main` before anything has been proved to work: the console still says
      // everything it said, and a report is written as well.
      final presented = <FlutterErrorDetails>[];
      FlutterError.onError = presented.add;

      final reporter = CrashReporter(clock: ticking())
        ..attach(reports)
        ..install();

      FlutterError.reportError(FlutterErrorDetails(
        exception: StateError('the compositor said no'),
        context: ErrorDescription('while laying out the timeline'),
      ));

      expect(presented, hasLength(1),
          reason: 'the previous handler still has to run');
      expect(reporter.count, 1);
      expect(reporter.text, contains('the compositor said no'));
      expect(reporter.text, contains('while laying out the timeline'));
    });
  });
}
