import 'dart:io';

/// What this installation has already been shown once.
///
/// A marker file whose *existence* is the whole fact, in the shape
/// [SessionMarker] already uses — no JSON, because there is nothing to say
/// beyond "yes", and a file that cannot be misparsed is one fewer way for the
/// tour to come back a second time or never come at all.
///
/// It lives under Application Support with the rest of the app's private
/// state rather than in the project library, because it is a fact about this
/// Mac and not about any project: somebody who copies a project onto a second
/// machine should get the tour there, having never seen it there.
///
/// Losing it is harmless in the direction that matters. A user who clears
/// Application Support is offered the tour again, which is a mild annoyance;
/// there is no failure mode where a first-time user is *not* offered it,
/// because a missing file reads as "not yet shown".
final class FirstRun {
  const FirstRun(this.tourMarker);

  final File tourMarker;

  /// True until [markTourSeen] has been called on this machine.
  bool get tourPending => !tourMarker.existsSync();

  /// Records that the tour has been offered, finished or skipped.
  ///
  /// Skipping counts. The tour is a thing to be got past, and an app that
  /// reads "Skip" as unfinished business shows it again next launch, which is
  /// how a sixty-second welcome becomes something people resent.
  ///
  /// It never throws: being unable to write the marker means the tour is
  /// offered again next time, and that is not worth failing a launch over.
  Future<void> markTourSeen() async {
    try {
      if (!tourMarker.parent.existsSync()) {
        await tourMarker.parent.create(recursive: true);
      }
      await tourMarker.writeAsString('', flush: true);
    } on FileSystemException {
      // Nothing to do and nobody to tell: see above.
    }
  }
}
