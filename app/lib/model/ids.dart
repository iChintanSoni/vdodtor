import 'dart:math';

/// Source of the opaque identifiers used for projects, tracks, clips and media.
///
/// Injectable so tests get stable ids: `IdGen.seeded(1)` produces the same
/// sequence every run, which keeps serialisation golden files readable.
final class IdGen {
  IdGen() : _random = Random.secure();
  IdGen.seeded(int seed) : _random = Random(seed);

  final Random _random;

  static const _alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';

  /// A short, URL-safe id. 10 chars of base-36 is ~52 bits — ample for the
  /// number of objects one project file will ever hold.
  String next([String prefix = '']) {
    final buf = StringBuffer(prefix);
    for (var i = 0; i < 10; i++) {
      buf.write(_alphabet[_random.nextInt(_alphabet.length)]);
    }
    return buf.toString();
  }
}
