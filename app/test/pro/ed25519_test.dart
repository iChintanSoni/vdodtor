import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/pro/ed25519.dart';

Uint8List unhex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

String hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  // RFC 8032 §7.1, TEST 1 and TEST 2. Ed25519 is deterministic, so a vector
  // pins the signer as exactly as it pins the verifier — which is what makes
  // this file worth more than a round trip: a round trip of two wrong
  // functions passes.
  group('RFC 8032', () {
    test('test 1: the empty message', () {
      final seed = unhex(
          '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60');
      expect(
        hex(Ed25519.publicKeyOf(seed)),
        'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
      );
      expect(
        hex(Ed25519.sign(seed: seed, message: const [])),
        'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e0652249015'
        '55fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
      );
    });

    test('test 2: one byte', () {
      final seed = unhex(
          '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb');
      expect(
        hex(Ed25519.publicKeyOf(seed)),
        '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
      );
      expect(
        hex(Ed25519.sign(seed: seed, message: const [0x72])),
        '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
        '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
      );
    });
  });

  // A vector this repository made, with something that is not this file:
  //
  //   openssl genpkey -algorithm ed25519 -out k.pem
  //   openssl pkeyutl -sign -inkey k.pem -rawin -in msg.bin -out sig.bin
  //
  // OpenSSL 3.6.3. Its message is 300 bytes, which is three SHA-512 blocks —
  // the RFC's first two vectors are one block each, so this is the only test
  // here that would notice a padding bug in the hash a signature is built on.
  test('agrees with OpenSSL over a long message', () {
    final seed = unhex(
        '9e0039ffbf2236e7e89ed953225edf1661f2a39be2e6eeeb4b738477ad23c1f5');
    final message = unhex(
        '3d289b94f2657e3d2085ac700fc415244cba24fb6d136e1c884d39503c5ebc8b'
        '40ccc6629ac6a4d55dd8a3b33065a535747567c7adcc9693f0c5585182810e15'
        '0c4fcbccbc1bb906fadabfa6a1210b99b0e1e5e48ec5e7beb210330c5cc038e5'
        '1176216de66c262b95b60b51836b7673efc2831d1a169aded930bb89fea2cd67'
        '55c18561e850d4799b93969fd25cc4913750ffc2297287b0b39d6c9638175976'
        '99aacd82b8a12112823a07c9a292e98bed4ea8d6d2186d93ee2d135536cb44fa'
        '9c3f1ae4acbb5d770733d54836ebf5125122f13083747026dbfdd331c7af0cf9'
        'f51f82901a0a0418d2d495a116f17bb615877090925c0cff5567254f9944d53b'
        '29191858959442e5130aba2e0781489113fec35bf38017a9e11dcd35a3a98863'
        '9d6b22bee77d55b82a486eb2');
    const signature =
        'b21fb1928c85a708238ceaedbf8ab316dc819c6c18696337b4322b8025860d6a'
        '5e054417c025c6bdd1544d76cdf310553297223e7988fed3b28e188ed76e1c09';

    expect(
      hex(Ed25519.publicKeyOf(seed)),
      '18b7f1493a6538922e6390a33a807309f99edcd6137ab58d41115b5d21577bc0',
    );
    expect(hex(Ed25519.sign(seed: seed, message: message)), signature);
    expect(
      Ed25519.verify(
        publicKey: Ed25519.publicKeyOf(seed),
        message: message,
        signature: unhex(signature),
      ),
      isTrue,
    );
  });

  group('verify says no', () {
    final seed = unhex(
        '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60');
    final publicKey = Ed25519.publicKeyOf(seed);
    final message = Uint8List.fromList('vdodtor pro'.codeUnits);
    final signature = Ed25519.sign(seed: seed, message: message);

    test('to a signature over a different message', () {
      expect(
        Ed25519.verify(
          publicKey: publicKey,
          message: Uint8List.fromList('vdodtor Pro'.codeUnits),
          signature: signature,
        ),
        isFalse,
      );
    });

    test('to a signature with one bit turned over', () {
      // Every byte, because a verifier that only checks the first half of a
      // signature passes a test that only tampers with the first half.
      for (var i = 0; i < signature.length; i++) {
        final tampered = Uint8List.fromList(signature)..[i] ^= 0x01;
        expect(
          Ed25519.verify(
            publicKey: publicKey,
            message: message,
            signature: tampered,
          ),
          isFalse,
          reason: 'byte $i of the signature was ignored',
        );
      }
    });

    test('to another key holder', () {
      final other = Ed25519.publicKeyOf(unhex(
          '4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb'));
      expect(
        Ed25519.verify(
          publicKey: other,
          message: message,
          signature: signature,
        ),
        isFalse,
      );
    });

    // Everything reaching this function came out of something a person
    // pasted, so nothing it is handed may throw.
    test('to rubbish, without throwing', () {
      expect(
        Ed25519.verify(publicKey: const [], message: message, signature: const []),
        isFalse,
      );
      expect(
        Ed25519.verify(
          publicKey: publicKey,
          message: message,
          signature: Uint8List(64),
        ),
        isFalse,
      );
      expect(
        Ed25519.verify(
          publicKey: Uint8List(32)..fillRange(0, 32, 0xff),
          message: message,
          signature: signature,
        ),
        isFalse,
      );
    });

    // S is reduced mod the group order, so S + L is a second encoding of a
    // signature that already verifies. Accepting both would make one licence
    // key into an unbounded family of them.
    test('to a scalar at or above the group order', () {
      final order = (BigInt.one << 252) +
          BigInt.parse('27742317777372353535851937790883648493');
      var s = BigInt.zero;
      for (var i = 63; i >= 32; i--) {
        s = (s << 8) | BigInt.from(signature[i]);
      }
      var raised = s + order;
      final malleable = Uint8List.fromList(signature);
      for (var i = 32; i < 64; i++) {
        malleable[i] = (raised & BigInt.from(0xff)).toInt();
        raised >>= 8;
      }
      expect(
        Ed25519.verify(
          publicKey: publicKey,
          message: message,
          signature: malleable,
        ),
        isFalse,
      );
    });
  });
}
