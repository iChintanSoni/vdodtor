import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/pro/entitlement.dart';

/// What the tier *means* is in `export_plan_test.dart`, beside everything else
/// the export sheet decides. This is the notifier alone: a fresh installation
/// is free, and a tier that changes says so once.
void main() {
  test('a fresh installation is free', () {
    expect(Entitlement.free().tier, Tier.free);
    expect(Entitlement.free().isPro, isFalse);
    expect(Entitlement().tier, Tier.free);
  });

  test('a granted tier is kept and announced', () {
    final entitlement = Entitlement();
    var notified = 0;
    entitlement.addListener(() => notified++);

    entitlement.grant(Tier.pro);
    expect(entitlement.tier, Tier.pro);
    expect(entitlement.isPro, isTrue);
    expect(notified, 1);
  });

  test('re-granting the tier it already has rebuilds nothing', () {
    // A licence is re-validated on every launch, and on most of them it says
    // what it said last time.
    final entitlement = Entitlement(Tier.pro);
    var notified = 0;
    entitlement.addListener(() => notified++);

    entitlement.grant(Tier.pro);
    expect(notified, 0);

    entitlement.grant(Tier.free);
    expect(entitlement.tier, Tier.free);
    expect(notified, 1);
  });
}
