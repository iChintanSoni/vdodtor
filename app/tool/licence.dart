// Mints and inspects vdodtor licence keys.
//
//   dart run tool/licence.dart keygen
//   dart run tool/licence.dart sign --key <seed hex> --id LS-1042 \
//       [--name "Ada Lovelace"] [--expires 2027-09-02] [--product vdodtor]
//   dart run tool/licence.dart check VDO1.…
//
// This is the fulfilment side. In production it is what the purchase webhook
// runs: an order comes in, this writes a key, the key goes in the receipt
// email. The private key is handed in on the command line and is not in this
// repository — `tool/licence_dev_key.txt` holds a *development* key whose
// private half is public on purpose, and which no shipped build may trust.
//
// It shares `lib/pro/licence.dart` with the app rather than reimplementing
// the format, which is the point: the writer and the reader are one file, so
// a key that this tool produces is a key the app can read by construction.

import 'dart:io';

import 'package:vdodtor/pro/ed25519.dart';
import 'package:vdodtor/pro/tier.dart';
import 'package:vdodtor/pro/licence.dart';

void main(List<String> argv) {
  final command = argv.isEmpty ? '' : argv.first;
  final options = _options(argv.skip(1));

  switch (command) {
    case 'keygen':
      _keygen();
    case 'sign':
      _sign(options);
    case 'check':
      _check(argv.length > 1 ? argv[1] : '');
    default:
      stderr.writeln('usage: licence.dart keygen | sign | check <key>');
      exit(64);
  }
}

void _keygen() {
  // 32 bytes from the platform's cryptographic source. Not `Random()`, which
  // is a pseudo-random generator seeded from the clock: a signing key anybody
  // can guess by knowing roughly when it was made is not a signing key.
  final seed = _randomSeed();
  final public = Ed25519.publicKeyOf(seed);
  stdout.writeln('seed   ${_hex(seed)}');
  stdout.writeln('public ${_hex(public)}');
  stdout.writeln();
  stdout.writeln('Paste `public` into vdodtorSigningKey in '
      'lib/pro/licence.dart.');
  stdout.writeln('Keep `seed` out of this repository. There is no way to '
      'recover it and no way to');
  stdout.writeln('revoke a key signed with it.');
}

void _sign(Map<String, String> options) {
  final seed = options['key'];
  final id = options['id'];
  if (seed == null || id == null) {
    stderr.writeln('sign needs --key <seed hex> and --id <order id>');
    exit(64);
  }

  final expires = options['expires'];
  final payload = licencePayload(
    id: id,
    tier: Tier.pro,
    name: options['name'] ?? '',
    expires: expires == null ? null : DateTime.parse(expires),
    product: options['product'] ?? vdodtorProduct,
  );

  final key = signLicence(seed: _unhex(seed), payload: payload);

  // Written back through the verifier before it is printed, because a
  // fulfilment tool that can emit a key the app rejects is worse than one
  // that cannot emit a key at all — the first failure would be somebody's
  // receipt.
  final check = LicenceVerifier(publicKey: _hex(Ed25519.publicKeyOf(_unhex(seed))))
      .check(key);
  if (!check.isInForce) {
    stderr.writeln('refusing to print a key the app rejects: '
        '${check.problem?.name}');
    exit(70);
  }

  stdout.writeln(key);
}

void _check(String key) {
  final check = LicenceVerifier.release.check(key);
  final licence = check.licence;
  if (licence == null) {
    stdout.writeln('rejected: ${check.problem?.name}');
    exit(1);
  }
  stdout.writeln('id      ${licence.id}');
  stdout.writeln('name    ${licence.name.isEmpty ? '—' : licence.name}');
  stdout.writeln('product ${licence.product}');
  stdout.writeln('tier    ${licence.tier.name}');
  stdout.writeln('issued  ${licence.issued}');
  stdout.writeln('expires ${licence.expires ?? 'never'}');
  stdout.writeln('status  ${check.problem?.name ?? 'in force'}');
  if (check.problem != null) exit(1);
}

List<int> _randomSeed() {
  final file = File('/dev/urandom').openSync();
  try {
    return file.readSync(Ed25519.keyBytes);
  } finally {
    file.closeSync();
  }
}

Map<String, String> _options(Iterable<String> argv) {
  final options = <String, String>{};
  final rest = argv.toList();
  for (var i = 0; i < rest.length; i++) {
    final arg = rest[i];
    if (!arg.startsWith('--')) continue;
    final equals = arg.indexOf('=');
    if (equals > 0) {
      options[arg.substring(2, equals)] = arg.substring(equals + 1);
    } else if (i + 1 < rest.length) {
      options[arg.substring(2)] = rest[++i];
    }
  }
  return options;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<int> _unhex(String text) => [
      for (var i = 0; i + 1 < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16)
    ];
