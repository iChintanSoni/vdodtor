/// What an installation may do — the value, with nothing attached to it.
///
/// Split out of `entitlement.dart` so that this file, and everything that
/// only needs to name a tier, imports no Flutter. `Entitlement` is a
/// [ChangeNotifier] and so drags in `dart:ui`, which is fine in an app and
/// fatal in `tool/licence.dart`: the fulfilment tool has to run under plain
/// `dart run`, and it has to build its payloads with the same enum the app
/// reads them back with. One value, two runtimes.
library;

/// What this installation may do.
///
/// Two values rather than a bag of feature flags, because the brief sells one
/// thing (§5): the *complete* editor is free at 1080p — no watermark, no
/// account, no ads, ever — and Pro is 4K export plus premium packs. A tier
/// that had to be consulted per feature would be a tier the editor was full
/// of, and every one of those checks would be a place the free version could
/// feel crippled. There are meant to be two: the size an export may be
/// written at, and which packs are installed.
///
/// The names cross into licence keys as text — `tier pro` is a signed line in
/// a payload — so renaming one renames it in every receipt ever sent.
enum Tier {
  free('Free'),
  pro('Pro');

  const Tier(this.label);

  final String label;

  bool get isPro => this == Tier.pro;
}
