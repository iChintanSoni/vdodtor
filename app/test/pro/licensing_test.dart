import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/pro/ed25519.dart';
import 'package:vdodtor/pro/licence.dart';
import 'package:vdodtor/pro/licence_store.dart';
import 'package:vdodtor/pro/licensing.dart';
import 'package:vdodtor/pro/tier.dart';

final _seed = List<int>.generate(32, (i) => (i * 11 + 5) & 0xff);
final _verifier = LicenceVerifier(
  publicKey: Ed25519.publicKeyOf(_seed)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(),
);

String mint({String id = 'LS-1', DateTime? expires}) => signLicence(
      seed: _seed,
      payload: licencePayload(
        id: id,
        tier: Tier.pro,
        name: 'Ada Lovelace',
        issued: DateTime.utc(2026, 1, 1),
        expires: expires,
      ),
    );

void main() {
  late Directory dir;
  final now = DateTime.utc(2026, 9, 2);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('vdodtor-licence');
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  Licensing licensing() => Licensing(
        store: FileLicenceStore(File('${dir.path}/licence.key')),
        verifier: _verifier,
        clock: () => now,
      );

  test('a fresh installation is free, and says nothing went wrong', () async {
    final pro = licensing();
    addTearDown(pro.dispose);
    await pro.load();

    expect(pro.isPro, isFalse);
    expect(pro.licence, isNull);
    expect(pro.problem, isNull);
  });

  test('activating a good key grants Pro and keeps it', () async {
    final pro = licensing();
    addTearDown(pro.dispose);
    await pro.load();

    var notifications = 0;
    pro.entitlement.addListener(() => notifications++);

    final check = await pro.activate(mint());
    expect(check.isInForce, isTrue);
    expect(pro.isPro, isTrue);
    expect(pro.licence!.name, 'Ada Lovelace');
    expect(notifications, 1);

    // The next launch, which is the whole of "restore" on the machine it was
    // bought on: the key is on disk and nothing has to be pasted again.
    final relaunched = licensing();
    addTearDown(relaunched.dispose);
    await relaunched.load();
    expect(relaunched.isPro, isTrue);
    expect(relaunched.licence!.id, 'LS-1');
  });

  test('the file holds the key exactly as it was pasted', () async {
    final pro = licensing();
    addTearDown(pro.dispose);
    final key = mint();
    await pro.activate('  $key\n');

    final stored = await File('${dir.path}/licence.key').readAsString();
    expect(stored.trim(), key);
  });

  test('a bad key changes nothing and is not written', () async {
    final pro = licensing();
    addTearDown(pro.dispose);
    await pro.load();

    final check = await pro.activate('VDO1.not.alicence');
    expect(check.problem, LicenceProblem.unrecognised);
    expect(pro.isPro, isFalse);
    expect(pro.licence, isNull);
    expect(File('${dir.path}/licence.key').existsSync(), isFalse);
  });

  test('a licence that has already lapsed is refused on the way in', () async {
    final pro = licensing();
    addTearDown(pro.dispose);
    final check = await pro.activate(mint(expires: DateTime.utc(2025, 1, 1)));

    expect(check.problem, LicenceProblem.expired);
    expect(check.licence, isNotNull, reason: 'the sheet has to say whose');
    expect(pro.isPro, isFalse);
    expect(File('${dir.path}/licence.key').existsSync(), isFalse);
  });

  // Deleting it would turn "your subscription lapsed on the 3rd" into "you
  // are on the free tier", which answers nothing.
  test('a stored licence that lapses is kept, and explains itself', () async {
    final bought = Licensing(
      store: FileLicenceStore(File('${dir.path}/licence.key')),
      verifier: _verifier,
      clock: () => DateTime.utc(2026, 1, 2),
    );
    addTearDown(bought.dispose);
    await bought.activate(mint(expires: DateTime.utc(2026, 2, 1)));
    expect(bought.isPro, isTrue);

    final later = licensing();
    addTearDown(later.dispose);
    await later.load();

    expect(later.isPro, isFalse);
    expect(later.problem, LicenceProblem.expired);
    expect(later.licence!.expires, DateTime.utc(2026, 2, 1));
    expect(File('${dir.path}/licence.key').existsSync(), isTrue);
  });

  test('deactivating takes it off this Mac and nothing else', () async {
    final pro = licensing();
    addTearDown(pro.dispose);
    final key = mint();
    await pro.activate(key);
    expect(pro.isPro, isTrue);

    await pro.deactivate();
    expect(pro.isPro, isFalse);
    expect(pro.licence, isNull);
    expect(pro.problem, isNull);
    expect(File('${dir.path}/licence.key').existsSync(), isFalse);

    // The key itself is untouched by that — there is no seat to give back,
    // and it goes straight into the next machine.
    expect((await pro.activate(key)).isInForce, isTrue);
  });

  test('an unreadable licence file is the same as no licence', () async {
    // A directory where the file should be: exists, and cannot be read as a
    // string.
    await Directory('${dir.path}/licence.key').create();
    final pro = licensing();
    addTearDown(pro.dispose);
    await pro.load();

    expect(pro.isPro, isFalse);
    expect(pro.licence, isNull);
  });

  test('the tier is not re-checked while the app runs', () async {
    // Bought at a moment when it is valid; the clock then passes the expiry
    // with the app still open. Nothing re-reads it, which is the point: an
    // export running when a subscription lapses finishes.
    var today = DateTime.utc(2026, 1, 2);
    final pro = Licensing(
      store: FileLicenceStore(File('${dir.path}/licence.key')),
      verifier: _verifier,
      clock: () => today,
    );
    addTearDown(pro.dispose);
    await pro.activate(mint(expires: DateTime.utc(2026, 2, 1)));

    today = DateTime.utc(2027, 1, 1);
    expect(pro.isPro, isTrue);
  });
}
