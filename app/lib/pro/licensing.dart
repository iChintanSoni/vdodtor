/// The licence, the file it lives in, and the tier it grants: one object, so
/// that there is one answer to "is this installation Pro" and one place that
/// works it out.
library;

import 'package:flutter/foundation.dart';

import 'entitlement.dart';
import 'licence.dart';
import 'licence_store.dart';

/// Reads the licence at launch, takes a pasted one, and removes it again.
///
/// It owns the [Entitlement] rather than being handed one, because the tier
/// is a *consequence* of the licence and having two objects that could
/// disagree about it would be having two tiers. Widgets go on listening to
/// the [Entitlement] — the export sheet does not care why it is allowed to
/// write 4K — and the licence sheet listens to this.
///
/// The expiry is checked when a licence is read and when one is pasted, and
/// not again. An editor that took Pro away in the middle of somebody's
/// session — mid-export, even — to enforce a date that passed while they were
/// working would be doing the one thing this product promises not to.
final class Licensing extends ChangeNotifier {
  Licensing({
    required this.store,
    this.verifier = LicenceVerifier.release,
    Entitlement? entitlement,
    DateTime Function()? clock,
  })  : entitlement = entitlement ?? Entitlement.free(),
        _clock = clock ?? DateTime.now;

  final LicenceStore store;
  final LicenceVerifier verifier;

  /// What this installation may do. Passed down to the export sheet, which
  /// never learns that a licence exists.
  final Entitlement entitlement;

  final DateTime Function() _clock;

  Licence? _licence;
  LicenceProblem? _problem;

  /// The purchase this Mac knows about, in force or not.
  Licence? get licence => _licence;

  /// Why [licence] is not granting anything. Null when there is no licence at
  /// all, and null when the one there is works.
  LicenceProblem? get problem => _problem;

  bool get isPro => entitlement.isPro;

  /// What this installation may do, as a value. The sheet asks for the tier
  /// rather than the yes/no when it has more than two things to say.
  Tier get tier => entitlement.tier;

  /// True when this build trusts a signing key whose private half is public.
  /// Surfaced so the sheet can say so; see [vdodtorSigningKey].
  bool get isDevelopmentBuild => isDevelopmentSigningKey;

  /// Reads whatever is on disk and settles the tier. Called once, at launch,
  /// before the window shows a project.
  ///
  /// A stored licence that no longer works is **kept**, not deleted. It is
  /// the evidence: "your subscription lapsed on the 3rd" is an answer, and
  /// "you are on the free tier" after silently binning their key is not.
  Future<void> load() async {
    final stored = await store.read();
    if (stored == null) {
      _settle(const LicenceCheck());
      return;
    }
    _settle(verifier.check(stored, now: _clock()));
  }

  /// Takes a pasted key. Stores it and lifts the tier if it is good; changes
  /// nothing at all if it is not.
  ///
  /// A rejected key is not written, deliberately — including an expired one.
  /// The alternative is an app that remembers every wrong thing anybody ever
  /// pasted into it, and the message it hands back already says what went
  /// wrong while the text is still in the field to be corrected.
  Future<LicenceCheck> activate(String pasted) async {
    final check = verifier.check(pasted, now: _clock());
    if (!check.isInForce) return check;

    await store.write(check.licence!.key);
    _settle(check);
    return check;
  }

  /// Removes the licence from this Mac.
  ///
  /// This is the whole of "deactivate". There is no seat count to give back
  /// because there is no server keeping one: the key stays valid, and the
  /// person who owns it can paste it into the machine they are moving to.
  /// What this is actually for is the machine they are moving *from* — a Mac
  /// being sold, or handed to somebody else — and for that, taking the file
  /// off it is the entire job.
  Future<void> deactivate() async {
    await store.remove();
    _settle(const LicenceCheck());
  }

  void _settle(LicenceCheck check) {
    _licence = check.licence;
    _problem = check.problem;
    entitlement.grant(check.isInForce ? check.licence!.tier : Tier.free);
    notifyListeners();
  }

  @override
  void dispose() {
    entitlement.dispose();
    super.dispose();
  }
}
