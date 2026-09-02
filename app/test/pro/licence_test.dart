import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/pro/ed25519.dart';
import 'package:vdodtor/pro/licence.dart';
import 'package:vdodtor/pro/tier.dart';

/// A keypair this file owns, so that nothing here depends on the development
/// key staying the development key — the day that constant is replaced with a
/// release key, these tests must go on passing unchanged.
final _seed = List<int>.generate(32, (i) => (i * 7 + 3) & 0xff);
final _verifier = LicenceVerifier(
  publicKey: Ed25519.publicKeyOf(_seed)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(),
);

String mint({
  String id = 'LS-1042',
  String name = 'Ada Lovelace',
  Tier tier = Tier.pro,
  DateTime? issued,
  DateTime? expires,
  String product = vdodtorProduct,
}) =>
    signLicence(
      seed: _seed,
      payload: licencePayload(
        id: id,
        tier: tier,
        name: name,
        issued: issued ?? DateTime.utc(2026, 1, 1),
        expires: expires,
        product: product,
      ),
    );

void main() {
  final now = DateTime.utc(2026, 9, 2);

  group('a licence in force', () {
    test('reads back what was signed into it', () {
      final check = _verifier.check(mint(), now: now);
      expect(check.isInForce, isTrue);
      expect(check.problem, isNull);

      final licence = check.licence!;
      expect(licence.id, 'LS-1042');
      expect(licence.name, 'Ada Lovelace');
      expect(licence.product, vdodtorProduct);
      expect(licence.tier, Tier.pro);
      expect(licence.issued, DateTime.utc(2026, 1, 1));
      expect(licence.isPerpetual, isTrue);
    });

    test('survives the whitespace of being pasted', () {
      final key = mint();
      expect(_verifier.check('  $key \n', now: now).isInForce, isTrue);
    });

    test('keeps the key it was given, so it can be stored verbatim', () {
      final key = mint();
      expect(_verifier.check(key, now: now).licence!.key, key);
    });

    test('has no name when none was bought under one', () {
      final check = _verifier.check(mint(name: ''), now: now);
      expect(check.isInForce, isTrue);
      expect(check.licence!.name, isEmpty);
    });
  });

  group('a subscription', () {
    test('works up to its date', () {
      final check = _verifier.check(
        mint(expires: DateTime.utc(2026, 12, 1)),
        now: now,
      );
      expect(check.isInForce, isTrue);
      expect(check.licence!.expires, DateTime.utc(2026, 12, 1));
      expect(check.licence!.isPerpetual, isFalse);
    });

    // A renewal receipt that lands on Tuesday must not stop an export on
    // Monday night.
    test('works through the grace period after it', () {
      final key = mint(expires: DateTime.utc(2026, 9, 1));
      expect(
        _verifier.check(key, now: DateTime.utc(2026, 9, 10)).isInForce,
        isTrue,
      );
      expect(
        _verifier.check(key, now: DateTime.utc(2026, 9, 30)).isInForce,
        isFalse,
      );
    });

    // The purchase is still real, and the sheet has to be able to say whose
    // it was and when it ran out. Only `problem` says it is not granting.
    test('is still readable once it has lapsed', () {
      final check = _verifier.check(
        mint(expires: DateTime.utc(2026, 1, 1)),
        now: now,
      );
      expect(check.isInForce, isFalse);
      expect(check.problem, LicenceProblem.expired);
      expect(check.licence, isNotNull);
      expect(check.licence!.name, 'Ada Lovelace');
      expect(check.licence!.lapsesAfter, DateTime.utc(2026, 1, 15));
    });
  });

  group('a licence that is not one', () {
    test('rejects an empty field with something to do about it', () {
      expect(_verifier.check('', now: now).problem, LicenceProblem.empty);
      expect(_verifier.check('   ', now: now).problem, LicenceProblem.empty);
    });

    test('rejects anything that is not shaped like a key', () {
      for (final rubbish in [
        'hello',
        'VDO1.only-two-parts',
        'VDO2.${mint().split('.').skip(1).join('.')}',
        'VDO1.!!!.!!!',
        mint().replaceFirst('VDO1.', ''),
      ]) {
        expect(
          _verifier.check(rubbish, now: now).problem,
          LicenceProblem.unrecognised,
          reason: rubbish,
        );
      }
    });

    // The whole point of the signature: every field is under it, so none of
    // them can be edited into something better.
    test('rejects a payload with a word changed', () {
      final parts = mint(expires: DateTime.utc(2026, 1, 1)).split('.');
      final payload = utf8.decode(base64Url.decode(
          parts[1].padRight((parts[1].length + 3) & ~3, '=')));
      final extended = payload.replaceFirst('expires 2026-01-01', 'expires 2099-01-01');
      final forged = 'VDO1.'
          '${base64Url.encode(utf8.encode(extended)).replaceAll('=', '')}.'
          '${parts[2]}';

      expect(_verifier.check(forged, now: now).problem, LicenceProblem.forged);
      expect(_verifier.check(forged, now: now).licence, isNull);
    });

    test('rejects a signature from somebody else', () {
      final other = LicenceVerifier(
        publicKey: Ed25519.publicKeyOf(List<int>.filled(32, 9))
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
      );
      expect(other.check(mint(), now: now).problem, LicenceProblem.forged);
    });

    test('rejects a licence for something else we might sell', () {
      expect(
        _verifier.check(mint(product: 'vdodtor-mobile'), now: now).problem,
        LicenceProblem.otherProduct,
      );
    });

    test('rejects a signed licence missing what a licence needs', () {
      final key = signLicence(
        seed: _seed,
        payload: 'product $vdodtorProduct\ntier pro',
      );
      expect(_verifier.check(key, now: now).problem, LicenceProblem.incomplete);
    });

    test('rejects a tier this build has never heard of', () {
      final key = signLicence(
        seed: _seed,
        payload: 'product $vdodtorProduct\nid LS-1\ntier studio',
      );
      expect(_verifier.check(key, now: now).problem, LicenceProblem.incomplete);
    });
  });

  // The signature is over the bytes that arrived, and parsing happens after.
  // That is what lets a key written by a later fulfilment tool — one that
  // records something this build does not read — still open this build.
  test('ignores fields it does not know, without breaking the signature', () {
    final key = signLicence(
      seed: _seed,
      payload: 'product $vdodtorProduct\n'
          'id LS-77\n'
          'tier pro\n'
          'seats 3\n'
          'purchased-with card\n',
    );
    final check = _verifier.check(key, now: now);
    expect(check.isInForce, isTrue);
    expect(check.licence!.id, 'LS-77');
  });

  // A line appended after the fact cannot verify, but a line appended *and*
  // duplicating one that was signed must not win even in the arrangement
  // where somebody has both halves.
  test('reads the first spelling of a field, not the last', () {
    final key = signLicence(
      seed: _seed,
      payload: 'product $vdodtorProduct\nid LS-9\ntier pro\ntier free',
    );
    expect(_verifier.check(key, now: now).licence!.tier, Tier.pro);
  });

  // A field ends at a newline, so a buyer's name is a place somebody else's
  // string could write a line into a licence — and by the time the reader sees
  // it, it is signed. It is stopped where payloads are written.
  test('a name cannot write a line of its own', () {
    final check = _verifier.check(
      mint(name: 'Bob\ntier free\nexpires 2000-01-01'),
      now: now,
    );

    expect(check.isInForce, isTrue);
    expect(check.licence!.tier, Tier.pro);
    expect(check.licence!.expires, isNull);
    expect(check.licence!.name, 'Bob tier free expires 2000-01-01');
  });

  test('the shipped signing key is a well-formed one', () {
    expect(vdodtorSigningKey, hasLength(64));
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(vdodtorSigningKey), isTrue);
  });
}
