/// What this installation has paid for.
///
/// One value, listened to, passed down — not a global and not a service
/// locator, so a test can hand a widget either answer and the shipping app has
/// exactly one place that decides.
library;

import 'package:flutter/foundation.dart';

import 'tier.dart';

export 'tier.dart';

/// This installation's tier, as something the window can listen to.
///
/// A [ChangeNotifier] rather than a plain value because unlocking happens
/// *while the app is running* — somebody buys Pro, or restores a purchase, and
/// the sheet they were looking at when they hit the gate has to stop saying
/// no without being closed and reopened.
///
/// Nothing in the shipping app calls [grant] yet: reading a licence off the
/// disk and validating it offline is the next item in M4, and this is the seam
/// it plugs into. Until then every installation is [Tier.free], which is the
/// honest default — an editor that let 4K through because the licence check
/// had not been written would be one that had to start refusing later.
final class Entitlement extends ChangeNotifier {
  /// Positional because the name would have to be `_tier` to satisfy the
  /// analyzer's initializing-formal rule, and a named parameter may not start
  /// with an underscore.
  Entitlement([this._tier = Tier.free]);

  /// What a fresh installation with no licence is, spelled out where it is
  /// read rather than left as a default argument at each call site.
  factory Entitlement.free() => Entitlement();

  Tier _tier;

  Tier get tier => _tier;

  bool get isPro => _tier.isPro;

  /// Records a tier. Idempotent, so a licence re-validated on every launch
  /// does not rebuild the window each time.
  void grant(Tier tier) {
    if (_tier == tier) return;
    _tier = tier;
    notifyListeners();
  }
}
