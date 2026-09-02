/// Ed25519 — the signature a licence is, and the only thing that makes one
/// real.
///
/// **Why a signature and not a code.** A licence has to be checkable with no
/// network: the brief sells an editor with no account, and an editor that
/// phoned home to find out whether it was allowed to run would be exactly the
/// product this one exists in opposition to. Anything symmetric — a hash of
/// the buyer's email, an HMAC, a checksum over a serial — has to ship the
/// secret that makes keys inside the app that checks them, which means the
/// first person to look can mint their own. Public-key signing is the only
/// arrangement where the thing that *verifies* a licence cannot *write* one,
/// and that asymmetry is the whole feature.
///
/// **Why written here.** RFC 8032 is a fixed target with published test
/// vectors; it has no versions to keep up with and nothing to maintain. A
/// package would be a third party in the path between somebody paying for
/// Pro and getting it. Sixty lines of field arithmetic that a vector pins
/// exactly is a smaller risk than that, and it keeps the check testable in
/// `flutter test` with no platform channel — which is what lets the whole
/// licensing flow have tests at all, and what will let the Windows port have
/// the same one.
///
/// [sign] is here beside [verify] even though the shipping app never calls
/// it: it is what `app/tool/licence.dart` mints licences with, and what lets
/// a test generate its own keypair rather than commit a private key to a
/// public repository. Shipping the *algorithm* costs nothing — a signer with
/// no private key can sign nothing, and the private key is not in this
/// repository and never will be.
library;

import 'dart:typed_data';

import 'sha512.dart';

/// The curve, as a namespace rather than an object: there is one Ed25519 and
/// an instance of it would be an instance of nothing.
abstract final class Ed25519 {
  /// Bytes in a public key, a seed, and half a signature.
  static const int keyBytes = 32;

  /// Bytes in a signature: R and S, each 32.
  static const int signatureBytes = 64;

  /// True if [signature] is [publicKey]'s signature over [message].
  ///
  /// Never throws and never asserts: every input to this function came from
  /// something a user pasted, and a malformed key is an answer of `false`
  /// rather than a crash report.
  static bool verify({
    required List<int> publicKey,
    required List<int> message,
    required List<int> signature,
  }) {
    if (publicKey.length != keyBytes) return false;
    if (signature.length != signatureBytes) return false;

    final rBytes = signature.sublist(0, 32);
    final s = _littleEndian(signature.sublist(32));
    // A scalar at or above the group order is a second encoding of a
    // signature that is already valid, and accepting both is how one
    // signature becomes two. RFC 8032 says reject; this rejects.
    if (s >= _order) return false;

    final a = _decodePoint(publicKey);
    if (a == null) return false;
    final r = _decodePoint(rBytes);
    if (r == null) return false;

    final k = _littleEndian(
          sha512(<int>[...rBytes, ...publicKey, ...message]),
        ) %
        _order;

    // [s]B == R + [k]A, compared on the encodings so that two projective
    // representations of the same point still agree.
    final left = _encodePoint(_scalarMultiply(_base, s));
    final right = _encodePoint(_add(r, _scalarMultiply(a, k)));
    return _sameBytes(left, right);
  }

  /// The public key a 32-byte [seed] produces.
  static Uint8List publicKeyOf(List<int> seed) {
    final scalar = _secretScalar(seed);
    return _encodePoint(_scalarMultiply(_base, scalar));
  }

  /// Signs [message] with [seed]. Deterministic: the same seed and message
  /// always produce the same 64 bytes, which is what lets a test assert on
  /// one.
  static Uint8List sign({
    required List<int> seed,
    required List<int> message,
  }) {
    if (seed.length != keyBytes) {
      throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
    }
    final expanded = sha512(seed);
    final scalar = _clamp(expanded.sublist(0, 32));
    final prefix = expanded.sublist(32);
    final publicKey = _encodePoint(_scalarMultiply(_base, scalar));

    final r = _littleEndian(sha512(<int>[...prefix, ...message])) % _order;
    final rBytes = _encodePoint(_scalarMultiply(_base, r));
    final k = _littleEndian(
          sha512(<int>[...rBytes, ...publicKey, ...message]),
        ) %
        _order;
    final s = (r + k * scalar) % _order;

    return Uint8List(signatureBytes)
      ..setRange(0, 32, rBytes)
      ..setRange(32, 64, _toLittleEndian(s, 32));
  }
}

// --- the field and the group ------------------------------------------------

final BigInt _q = (BigInt.one << 255) - BigInt.from(19);

/// The order of the base point's subgroup: 2^252 + a number RFC 8032 spells
/// out in full, and so does this.
final BigInt _order = (BigInt.one << 252) +
    BigInt.parse('27742317777372353535851937790883648493');

/// The curve constant, −121665/121666.
final BigInt _d =
    (_q - BigInt.from(121665)) * _inverse(BigInt.from(121666)) % _q;

/// A square root of −1, used to pick the other root when decompressing.
final BigInt _sqrtMinusOne =
    BigInt.two.modPow((_q - BigInt.one) ~/ BigInt.from(4), _q);

/// The base point, from its y coordinate 4/5 with an even x.
final _Point _base = _decodePoint(_baseEncoding())!;

Uint8List _baseEncoding() {
  final y = BigInt.from(4) * _inverse(BigInt.from(5)) % _q;
  return _toLittleEndian(y, 32);
}

BigInt _inverse(BigInt a) => a.modPow(_q - BigInt.two, _q);

/// A point in extended coordinates: x = X/Z, y = Y/Z, xy = T/Z.
///
/// Extended rather than affine because affine addition needs a modular
/// inverse per step and a scalar multiply takes five hundred of them —
/// milliseconds become seconds, and this runs while the window is opening.
final class _Point {
  const _Point(this.x, this.y, this.z, this.t);

  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;
}

/// The unified addition formula for a = −1, which is complete on this curve:
/// no special case for doubling, none for the identity, and so no branch that
/// only some inputs take.
_Point _add(_Point p, _Point q) {
  final a = (p.y - p.x) * (q.y - q.x) % _q;
  final b = (p.y + p.x) * (q.y + q.x) % _q;
  final c = p.t * BigInt.two % _q * _d % _q * q.t % _q;
  final d = p.z * BigInt.two % _q * q.z % _q;
  final e = b - a;
  final f = d - c;
  final g = d + c;
  final h = b + a;
  return _Point(e * f % _q, g * h % _q, f * g % _q, e * h % _q);
}

final _Point _identity =
    _Point(BigInt.zero, BigInt.one, BigInt.one, BigInt.zero);

_Point _scalarMultiply(_Point p, BigInt scalar) {
  var result = _identity;
  var addend = p;
  var n = scalar;
  // Least-significant bit first, so the loop stops at the scalar's own
  // length instead of always walking 256 bits.
  while (n > BigInt.zero) {
    if (n.isOdd) result = _add(result, addend);
    addend = _add(addend, addend);
    n >>= 1;
  }
  return result;
}

Uint8List _encodePoint(_Point p) {
  final inverseZ = _inverse(p.z);
  final x = p.x * inverseZ % _q;
  final y = p.y * inverseZ % _q;
  final out = _toLittleEndian(y, 32);
  // The sign of x rides in the top bit of y, which is spare because y < 2^255.
  if (x.isOdd) out[31] |= 0x80;
  return out;
}

/// The inverse of [_encodePoint], or null if the 32 bytes are not a point.
_Point? _decodePoint(List<int> encoded) {
  final bytes = Uint8List.fromList(encoded);
  final sign = bytes[31] >> 7;
  bytes[31] &= 0x7f;
  final y = _littleEndian(bytes);
  // Non-canonical y — one that is a value mod q written the long way — is a
  // second encoding of a point that already has one, so it is rejected.
  if (y >= _q) return null;

  final y2 = y * y % _q;
  final u = (y2 - BigInt.one) % _q;
  final v = (_d * y2 + BigInt.one) % _q;

  // x = (u/v)^((q+3)/8), the closed form for a square root modulo a prime
  // congruent to 5 mod 8, written so that no inverse is taken: u·v^3·(u·v^7)^k.
  final v3 = v * v % _q * v % _q;
  final v7 = v3 * v3 % _q * v % _q;
  var x = u *
      v3 %
      _q *
      (u * v7 % _q).modPow((_q - BigInt.from(5)) ~/ BigInt.from(8), _q) %
      _q;

  var check = v * x % _q * x % _q;
  if (check != u % _q) {
    if ((check + u) % _q == BigInt.zero) {
      // The other root: this y has a square root, but it was −x.
      x = x * _sqrtMinusOne % _q;
    } else {
      return null;
    }
  }
  check = v * x % _q * x % _q;
  if (check != u % _q) return null;

  // x = 0 has one root, not two, so the sign bit would be claiming a point
  // that does not exist.
  if (x == BigInt.zero && sign == 1) return null;
  if ((x.isOdd ? 1 : 0) != sign) x = _q - x;

  return _Point(x, y, BigInt.one, x * y % _q);
}

/// The private scalar a seed expands to, clamped as RFC 8032 requires.
BigInt _secretScalar(List<int> seed) {
  if (seed.length != Ed25519.keyBytes) {
    throw ArgumentError.value(seed.length, 'seed', 'must be 32 bytes');
  }
  return _clamp(sha512(seed).sublist(0, 32));
}

/// Clearing the low three bits makes every scalar a multiple of the cofactor,
/// which keeps a small-order point out of the result; setting bit 254 fixes
/// the scalar's length so that a square-and-multiply takes the same number of
/// steps whatever the key is.
BigInt _clamp(Uint8List half) {
  half[0] &= 0xf8;
  half[31] &= 0x7f;
  half[31] |= 0x40;
  return _littleEndian(half);
}

BigInt _littleEndian(List<int> bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}

Uint8List _toLittleEndian(BigInt value, int length) {
  final out = Uint8List(length);
  var v = value;
  for (var i = 0; i < length; i++) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
