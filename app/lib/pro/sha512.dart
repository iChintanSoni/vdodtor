/// SHA-512, because Ed25519 is defined in terms of it.
///
/// Written here rather than pulled in, for the reason the whole of
/// [Ed25519] is: a licence check is the one piece of the app that has to
/// work with no network, no account and no service, and a dependency that
/// could vanish or change its API is a dependency that could one day refuse
/// somebody the thing they paid for. This is a hash function whose test
/// vectors have been published since 2001; it will not need maintaining.
///
/// It is 64-bit integer arithmetic throughout, which the Dart VM gives us
/// natively — `int` is 64-bit two's complement and `+`, `<<` and `>>>` wrap
/// and shift as the specification wants. On the web `int` is a double and
/// none of that holds; this is a desktop editor, and the analyzer would have
/// to be told otherwise before that mattered.
library;

import 'dart:typed_data';

/// The digest of [message], 64 bytes.
Uint8List sha512(List<int> message) {
  final h = Int64List.fromList(_initial);
  final w = Int64List(80);

  final block = Uint8List(128);
  final total = message.length;
  var offset = 0;

  // Whole blocks straight out of the message, then one or two padded blocks
  // built here. Splitting it this way keeps the padding in one place rather
  // than copying the entire message to append nine bytes to it.
  while (total - offset >= 128) {
    block.setRange(0, 128, message, offset);
    _compress(h, w, block);
    offset += 128;
  }

  final tail = total - offset;
  block.fillRange(0, 128, 0);
  block.setRange(0, tail, message, offset);
  block[tail] = 0x80;

  if (tail >= 112) {
    _compress(h, w, block);
    block.fillRange(0, 128, 0);
  }

  // The length in bits, big-endian, in the last 16 bytes. The high eight are
  // left zero: a message of 2^61 bytes is not a licence key.
  final bits = total * 8;
  for (var i = 0; i < 8; i++) {
    block[127 - i] = (bits >>> (8 * i)) & 0xff;
  }
  _compress(h, w, block);

  final out = Uint8List(64);
  for (var i = 0; i < 8; i++) {
    for (var b = 0; b < 8; b++) {
      out[i * 8 + b] = (h[i] >>> (56 - 8 * b)) & 0xff;
    }
  }
  return out;
}

int _rotr(int x, int n) => (x >>> n) | (x << (64 - n));

void _compress(Int64List h, Int64List w, Uint8List block) {
  for (var t = 0; t < 16; t++) {
    var v = 0;
    for (var b = 0; b < 8; b++) {
      v = (v << 8) | block[t * 8 + b];
    }
    w[t] = v;
  }
  for (var t = 16; t < 80; t++) {
    final x = w[t - 15];
    final y = w[t - 2];
    final s0 = _rotr(x, 1) ^ _rotr(x, 8) ^ (x >>> 7);
    final s1 = _rotr(y, 19) ^ _rotr(y, 61) ^ (y >>> 6);
    w[t] = w[t - 16] + s0 + w[t - 7] + s1;
  }

  var a = h[0], b = h[1], c = h[2], d = h[3];
  var e = h[4], f = h[5], g = h[6], hh = h[7];

  for (var t = 0; t < 80; t++) {
    final s1 = _rotr(e, 14) ^ _rotr(e, 18) ^ _rotr(e, 41);
    final ch = (e & f) ^ (~e & g);
    final t1 = hh + s1 + ch + _k[t] + w[t];
    final s0 = _rotr(a, 28) ^ _rotr(a, 34) ^ _rotr(a, 39);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = s0 + maj;

    hh = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }

  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
  h[5] += f;
  h[6] += g;
  h[7] += hh;
}

/// The eighty round constants and the eight starting words, derived rather
/// than transcribed.
///
/// FIPS 180-4 defines them as the first 64 bits of the fractional parts of
/// the cube roots (the constants) and the square roots (the starting words)
/// of the first primes, and that definition is *shorter than the table it
/// produces*. Eighty-eight hand-copied 64-bit hex literals are eighty-eight
/// chances to transpose a digit, and a single wrong one produces a hash that
/// is wrong for every input and looks exactly like a correct one. Twenty
/// lines of arithmetic a reviewer can check against the specification is the
/// same bargain `tools/make_luts.dart` takes: the formula is the artefact.
///
/// The published values are asserted in `app/test/pro/sha512_test.dart`
/// alongside the standard digests, so a mistake here fails loudly and in the
/// place that names it.
final Int64List _k = _fractionalRoots(80, 3);
final Int64List _initial = _fractionalRoots(8, 2);

/// `floor(frac(prime ** (1/root)) * 2**64)` for the first [count] primes.
Int64List _fractionalRoots(int count, int root) {
  final out = Int64List(count);
  var candidate = 1;
  for (var i = 0; i < count; i++) {
    candidate = _nextPrime(candidate);
    final p = BigInt.from(candidate);
    // (p << 64*root) ** (1/root) is exactly p ** (1/root) << 64, so the
    // integer root of the shifted value carries 64 bits of the fraction.
    final scaled = _integerRoot(p << (64 * root), root);
    final whole = _integerRoot(p, root) << 64;
    // toSigned before toInt because BigInt.toInt clamps rather than wraps,
    // and every constant with its top bit set is above the signed maximum.
    out[i] = (scaled - whole).toSigned(64).toInt();
  }
  return out;
}

int _nextPrime(int after) {
  var n = after + 1;
  while (true) {
    var prime = n > 1;
    for (var d = 2; d * d <= n; d++) {
      if (n % d == 0) {
        prime = false;
        break;
      }
    }
    if (prime) return n;
    n++;
  }
}

/// The largest integer whose [root]th power is at most [n]. Newton's method
/// from above, so the sequence decreases to the floor and stops there.
BigInt _integerRoot(BigInt n, int root) {
  if (n < BigInt.two) return n;
  final r = BigInt.from(root);
  var x = BigInt.one << (n.bitLength ~/ root + 1);
  while (true) {
    final next = ((r - BigInt.one) * x + n ~/ x.pow(root - 1)) ~/ r;
    if (next >= x) return x;
    x = next;
  }
}
