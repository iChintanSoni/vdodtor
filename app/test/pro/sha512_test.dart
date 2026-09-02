import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/pro/sha512.dart';

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // FIPS 180-4 and the NIST examples. These are the whole of the argument
  // that deriving the constants from the primes was safe: get one of them
  // wrong and none of these digests come out.
  test('digests the published examples', () {
    expect(
      hex(sha512(const [])),
      'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce'
      '47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e',
    );
    expect(
      hex(sha512(utf8.encode('abc'))),
      'ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a'
      '2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f',
    );
    expect(
      hex(sha512(utf8.encode(
          'abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn'
          'hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu'))),
      '8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018'
      '501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909',
    );
  });

  // The block-boundary cases the padding has to get right: a message that
  // leaves room for the length, one that does not and needs a second padded
  // block, and one that is an exact multiple of the block size.
  test('pads across every block boundary', () {
    final seen = <String>{};
    for (final length in [0, 111, 112, 127, 128, 129, 256]) {
      final digest = sha512(List<int>.filled(length, 0x61));
      expect(digest, hasLength(64));
      expect(seen.add(hex(digest)), isTrue, reason: 'length $length collided');
    }
  });

  test('hashes a million a-s', () {
    expect(
      hex(sha512(List<int>.filled(1000000, 0x61))),
      'e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973eb'
      'de0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b',
    );
  });
}
