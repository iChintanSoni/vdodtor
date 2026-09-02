/// What went wrong, written down where the person it happened to can read it.
///
/// **vdodtor cannot send a crash report, so it does not try.** There is no
/// `com.apple.security.network.client` entitlement in `Release.entitlements`
/// — see [About.download] for the whole of that argument — which means every
/// design that begins "the app uploads a report" is unavailable before it is
/// evaluated. What is left is the arrangement in this file: a fault is written
/// to a text file on the user's own disk, the app offers it the next time it
/// starts, and it reaches us only if a person reads it and pastes it into a
/// bug report.
///
/// That is **opt-in in the strongest form the word has**. The usual version is
/// a checkbox next to a server, and it asks the user to believe that the box
/// does what it says; here there is no server to consent to, the consent *is*
/// the paste, and the claim is checkable in ten seconds with
/// `codesign -d --entitlements`. The same reasoning ends the analytics
/// question in the same place: none, not even an anonymous count, because a
/// counter would need the entitlement that the promise above is made of.
///
/// **What a report is scrubbed of, and when.** Absolute file paths are
/// replaced with `<path>` — see [CrashReport.redact] — *before the file is
/// written*, not before it is shown, so there is no unscrubbed copy anywhere
/// on the disk for anything later to find. The rule catches the systematic
/// leak: a path is where the user's account name, their folder layout and the
/// names of their footage would otherwise appear, and a stack trace is full of
/// them. It cannot catch a bare filename that an error message happened to
/// quote, which is one more reason nothing here is sent automatically — the
/// user sees the exact bytes they would be pasting.
///
/// **What this cannot see.** A fault in the C engine — a signal in the
/// compositor, a bad pointer in a decoder — kills the process before Dart gets
/// another turn, and macOS writes that one to `~/Library/Logs/
/// DiagnosticReports`, which a sandboxed app is not granted and so cannot
/// read. So this covers Dart faults only, and the sheet says where the other
/// kind lives rather than pretending the list is complete. The project half of
/// a hard exit is already covered from the other direction, by
/// `SessionMarker`: the chooser offers the project back.
library;

import 'dart:io';

// `PlatformDispatcher` comes through here too, which is why there is no
// `dart:ui` import beside it.
import 'package:flutter/foundation.dart';

import 'about.dart';

/// One fault: when it happened, what this build was, and where in the code.
///
/// A value rather than a parser, because the file it writes is the artefact —
/// the thing somebody pastes — and reading one back is [CrashReporter.text]'s
/// job, which does it by reading the file as it stands. Two representations of
/// a report would be two things that could disagree about what was in it.
@immutable
final class CrashReport {
  const CrashReport({
    required this.when,
    required this.context,
    required this.summary,
    required this.stack,
    required this.version,
    required this.system,
  });

  /// UTC. A crash report timestamped in local time is a crash report whose
  /// order changes when somebody flies somewhere.
  final DateTime when;

  /// What the app was doing: "while building a widget", "outside any
  /// handler". Flutter supplies one for framework errors and it is the single
  /// most useful line in the file.
  final String context;

  /// The exception, as it described itself. Already redacted.
  final String summary;

  /// The stack, already redacted. Empty when there was none.
  final String stack;

  final String version;

  /// The machine, to the extent that it is about the machine: which macOS,
  /// which Dart. Not the hostname, not the account, not an id — none of those
  /// help with a bug and all of them identify somebody.
  final String system;

  /// Builds one out of what an error handler is handed, redacting as it goes.
  factory CrashReport.of(
    Object error,
    StackTrace? stack, {
    required String context,
    required DateTime when,
    String version = About.version,
    String? system,
  }) =>
      CrashReport(
        when: when.toUtc(),
        context: context,
        summary: redact(_describe(error)),
        stack: redact(stack?.toString().trimRight() ?? ''),
        version: version,
        system: system ?? describeSystem(),
      );

  /// The file, exactly as it is written and exactly as it is shown.
  ///
  /// The first line is there for the copy that ends up pasted somewhere with
  /// none of this file's context around it: whoever reads it should not have
  /// to wonder whether it was collected from the user or handed over by them.
  String get text => [
        'vdodtor problem report — written on this machine, sent nowhere.',
        '',
        'version   $version',
        'when      ${when.toIso8601String()}',
        'system    $system',
        'context   $context',
        '',
        summary,
        if (stack.isNotEmpty) ...['', stack],
        '',
      ].join('\n');

  /// The name of the file this is kept in.
  ///
  /// The timestamp is in the name and the name sorts by it, so listing the
  /// directory in reverse alphabetical order lists the reports newest first —
  /// which saves reading ten files to find out which one is the newest one.
  /// Colons are legal in a Mac filename and awful in every other context a
  /// path gets pasted into, so the time separators are dashes.
  String get fileName {
    final iso = when.toIso8601String().split('.').first.replaceAll(':', '-');
    return 'crash-${iso}Z.txt';
  }

  /// Every file listed here is one of these.
  static const filePrefix = 'crash-';

  /// Replaces absolute file paths with `<path>`, keeping the extension.
  ///
  /// The extension is kept and everything before it is not, because the
  /// diagnostic value of a path in a crash is almost always "it was a `.mov`"
  /// and the private part is all the rest of it. `package:` URIs are left
  /// alone — they are the whole worth of a stack trace and they name our own
  /// source rather than anybody's disk — which falls out of a path having to
  /// start at a boundary: the slash in `package:vdodtor/ui/x.dart` is preceded
  /// by a word character, and so is the one in `https://vdodtor.app/pro`.
  static String redact(String text) =>
      text.replaceAllMapped(_absolutePath, (match) {
        final path = match[2]!;
        final segment = path.split('/').last;
        final dot = segment.lastIndexOf('.');
        final extension = dot > 0 ? segment.substring(dot) : '';
        return '${match[1]}<path>'
            '${_plainExtension.hasMatch(extension) ? extension : ''}';
      });

  /// A boundary, an optional `file://`, and then a path with something in it.
  ///
  /// Requiring at least one character after the slash is what stops a lone
  /// divide in a message — "3 / 4" — reading as a path to nowhere.
  static final _absolutePath = RegExp(
    '''([\\s"'(\\[<=,]|^)((?:file://)?/[^\\s"'()\\[\\]<>,]+)''',
    multiLine: true,
  );

  /// `.mov`, not `.dart:118:7`. An "extension" that is really the rest of a
  /// stack frame says where in somebody's home directory the file was.
  static final _plainExtension = RegExp(r'^\.[A-Za-z0-9]{1,8}$');

  /// Which macOS and which Dart, and nothing else.
  static String describeSystem() =>
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion} · '
      'Dart ${Platform.version.split(' ').first}';

  /// `FlutterErrorDetails` hands over the exception itself, and some of them
  /// describe themselves across several lines with a stack of their own in
  /// the middle. One line, so the file's header stays a header.
  static String _describe(Object error) {
    final text = error.toString().trim();
    return text.isEmpty ? error.runtimeType.toString() : text;
  }
}

/// Catches Dart faults, keeps the last few on disk, and says whether there is
/// one the user has not been shown.
///
/// A [ChangeNotifier] on `Licensing`'s terms — the chooser's banner listens to
/// it — but with one rule that is worth stating because it looks like an
/// omission: **[record] does not notify.** It is called from
/// `FlutterError.onError`, which runs in the middle of build, layout or paint,
/// and scheduling a repaint from inside a failing frame is a second failure
/// stacked on the first one. So the banner reflects what was on disk when the
/// app started; a report written while the app is running is offered at the
/// next launch, which is when somebody is in a position to read it anyway.
final class CrashReporter extends ChangeNotifier {
  CrashReporter({
    DateTime Function()? clock,
    this.version = About.version,
    this.keep = 10,
  }) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final String version;

  /// How many reports are kept. A crash that repeats every launch must not
  /// fill somebody's disk, and the tenth-oldest report of the same fault
  /// answers nothing the newest one does not.
  final int keep;

  Directory? _directory;

  /// Faults that happened before storage was resolved — during font loading,
  /// or while working out where storage even is. Bounded, because the case
  /// where this matters is a fault that repeats.
  final List<CrashReport> _pending = [];

  /// Guards against a fault raised while handling a fault. Nothing in [record]
  /// should be able to raise a Flutter error, but a reporter that can recurse
  /// turns one bug into a hang, and the guard is cheaper than the certainty.
  bool _recording = false;

  /// The newest report at the moment the user last saw the offer.
  String? _seen;

  /// Takes over the two handlers Dart faults arrive through.
  ///
  /// Both chain rather than replace: `FlutterError.onError` keeps printing to
  /// the console, and `PlatformDispatcher.onError` returns false so the
  /// platform still reports what it always did. This adds a recorder and
  /// changes nothing else, which is what makes it safe to install in `main`
  /// before anything has been proved to work.
  void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      record(
        details.exception,
        details.stack,
        context: details.context?.toString() ?? 'in the framework',
      );
      previous?.call(details);
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, context: 'outside any handler');
      return false;
    };
  }

  /// Points the reporter at the directory reports live in, writes anything
  /// that happened before there was one, and prunes.
  void attach(Directory directory) {
    _directory = directory;
    try {
      if (!directory.existsSync()) directory.createSync(recursive: true);
      for (final report in _pending) {
        _write(report);
      }
      _seen = _readSeen();
      _prune();
    } on FileSystemException {
      // Reports are a courtesy; the app runs without them. The user is
      // already dealing with whatever caused the fault.
    }
    _pending.clear();
    notifyListeners();
  }

  /// Writes one fault down. Never throws, and never notifies — see the class
  /// comment for why the second one is deliberate.
  void record(Object error, StackTrace? stack, {required String context}) {
    if (_recording) return;
    _recording = true;
    try {
      final report = CrashReport.of(
        error,
        stack,
        context: context,
        when: _clock(),
        version: version,
      );
      if (_directory == null) {
        if (_pending.length < keep) _pending.add(report);
        return;
      }
      _write(report);
      _prune();
    } catch (_) {
      // A crash reporter that can crash is the one component where a bug
      // costs more than the bug it was reporting.
    } finally {
      _recording = false;
    }
  }

  /// The reports on disk, newest first.
  List<File> get reports {
    final directory = _directory;
    if (directory == null || !directory.existsSync()) return const [];
    try {
      final files = directory
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => _nameOf(f).startsWith(CrashReport.filePrefix))
          .toList()
        ..sort((a, b) => _nameOf(b).compareTo(_nameOf(a)));
      return files;
    } on FileSystemException {
      return const [];
    }
  }

  int get count => reports.length;

  /// True when the newest report is not the one the user was last offered.
  ///
  /// Kept rather than derived from "was this launch the one that crashed",
  /// because the fault that matters most is the one that killed the app before
  /// it could tell anybody — and the next launch is the first chance to.
  bool get hasUnseen {
    final files = reports;
    return files.isNotEmpty && _nameOf(files.first) != _seen;
  }

  /// Everything there is, newest first, as one document.
  ///
  /// Concatenated rather than listed: three reports of the same fault are read
  /// top to bottom in a few seconds, and a picker would be a piece of
  /// furniture in front of a text file.
  String get text {
    final parts = <String>[];
    for (final file in reports) {
      try {
        parts.add(file.readAsStringSync().trimRight());
      } on FileSystemException {
        // A report that cannot be read is a report that is not there.
      }
    }
    return parts.join('\n\n${'—' * 40}\n\n');
  }

  /// Records that the offer has been made, so it is not made again for the
  /// same fault. The reports themselves stay: dismissing a banner is not
  /// asking for evidence to be destroyed.
  void markSeen() {
    final files = reports;
    if (files.isEmpty) return;
    _seen = _nameOf(files.first);
    try {
      _seenFile?.writeAsStringSync('$_seen\n', flush: true);
    } on FileSystemException {
      // Then the offer is made once more next launch, which is the harmless
      // direction for this to fail in.
    }
    notifyListeners();
  }

  /// Throws the lot away, at the user's request. The one button in the app
  /// that is about their privacy rather than their footage.
  void deleteAll() {
    for (final file in reports) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Nothing to do: it is either gone or not ours to remove.
      }
    }
    try {
      final seen = _seenFile;
      if (seen != null && seen.existsSync()) seen.deleteSync();
    } on FileSystemException {
      // As above.
    }
    _seen = null;
    notifyListeners();
  }

  /// Not a report, so it is a dotfile and [reports] filters it out by prefix.
  File? get _seenFile {
    final directory = _directory;
    return directory == null ? null : File('${directory.path}/.seen');
  }

  String? _readSeen() {
    try {
      final seen = _seenFile;
      if (seen == null || !seen.existsSync()) return null;
      final name = seen.readAsStringSync().trim();
      return name.isEmpty ? null : name;
    } on FileSystemException {
      return null;
    }
  }

  void _write(CrashReport report) {
    final directory = _directory;
    if (directory == null) return;
    var file = File('${directory.path}/${report.fileName}');
    // Two faults inside one second are one fault twice, most of the time —
    // but overwriting the first with the second would lose the one that
    // started it, which is the one worth having.
    for (var attempt = 2; file.existsSync() && attempt < 100; attempt++) {
      file = File('${directory.path}/'
          '${report.fileName.replaceFirst('.txt', '-$attempt.txt')}');
    }
    file.writeAsStringSync(report.text, flush: true);
  }

  void _prune() {
    final files = reports;
    for (final file in files.skip(keep)) {
      try {
        file.deleteSync();
      } on FileSystemException {
        // Then it is pruned next time, or never, and the directory is one
        // file bigger than intended.
      }
    }
  }

  static String _nameOf(File file) => file.uri.pathSegments.last;
}
