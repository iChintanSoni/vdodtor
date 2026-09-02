// Builds and inspects vdodtor content packs.
//
//   dart run tool/pack.dart build --from ../build/packs/cinema \
//       --key <seed hex> --out assets/packs/cinema.vdpack
//   dart run tool/pack.dart show assets/packs/cinema.vdpack
//
// `--from` is a directory holding a `pack.manifest` and the files it names;
// `tools/make_luts.dart` writes both, from the same list of formulae that
// produced the cubes, so the manifest and its contents cannot drift apart.
//
// The signing key is handed in on the command line and is not in this
// repository — `tool/licence_dev_key.txt` holds a *development* key whose
// private half is public on purpose. A pack is signed with the same key a
// licence is: one secret to look after rather than two, and splitting them
// later is a constant in lib/pro/pack.dart.
//
// It shares `lib/pro/pack.dart` with the app rather than reimplementing the
// container, so a pack this prints is one the app can open by construction —
// which `build` then proves by reading its own output back before writing it.

import 'dart:io';
import 'dart:typed_data';

import 'package:vdodtor/pro/ed25519.dart';
import 'package:vdodtor/pro/pack.dart';

void main(List<String> argv) {
  final command = argv.isEmpty ? '' : argv.first;
  switch (command) {
    case 'build':
      _build(_options(argv.skip(1)));
    case 'show':
      _show(argv.length > 1 ? argv[1] : '');
    default:
      stderr.writeln('usage: pack.dart build --from <dir> --key <seed hex> '
          '--out <file> | show <file>');
      exit(64);
  }
}

void _build(Map<String, String> options) {
  final from = options['from'];
  final seed = options['key'];
  final out = options['out'];
  if (from == null || seed == null || out == null) {
    stderr.writeln('build needs --from, --key and --out');
    exit(64);
  }

  final manifestFile = File('$from/pack.manifest');
  if (!manifestFile.existsSync()) {
    stderr.writeln('no pack.manifest in $from');
    exit(66);
  }

  final manifest = PackManifest.parse(manifestFile.readAsStringSync());
  if (manifest == null) {
    stderr.writeln('$from/pack.manifest is not a usable manifest');
    exit(65);
  }

  final files = <String, Uint8List>{};
  for (final item in manifest.items) {
    final file = File('$from/${item.file}');
    if (!file.existsSync()) {
      stderr.writeln('${item.name} names ${item.file}, which is not in $from');
      exit(66);
    }
    files[item.file] = file.readAsBytesSync();
  }

  final bytes = PackFile.write(
    manifest: manifest,
    files: files,
    seed: _unhex(seed),
  );

  // Read back through the app's own reader before anything is written, with
  // the key this was signed with. A builder that can emit a pack the app
  // refuses is worse than one that cannot emit a pack at all: the first
  // failure would be somebody's download.
  final read = PackFile.read(
    bytes,
    publicKey: _hex(Ed25519.publicKeyOf(_unhex(seed))),
  );
  if (!read.isReadable) {
    stderr.writeln('refusing to write a pack the app rejects: '
        '${read.problem?.name}');
    exit(70);
  }

  File(out)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  stdout.writeln('$out  (${files.length} files, ${bytes.length} bytes)');
  _describe(read.pack!.manifest);
}

void _show(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('no such file: $path');
    exit(66);
  }

  final read = PackFile.read(file.readAsBytesSync());
  final pack = read.pack;
  if (pack == null) {
    stdout.writeln('rejected: ${read.problem?.name}');
    exit(1);
  }

  _describe(pack.manifest);
  for (final item in pack.manifest.items) {
    final bytes = pack.files[item.file];
    stdout.writeln('  ${item.kind.key.padRight(5)} ${item.name} '
        '(${item.file}, ${bytes == null ? 'MISSING' : '${bytes.length} bytes'})');
  }
}

void _describe(PackManifest manifest) {
  stdout.writeln('id      ${manifest.id}');
  stdout.writeln('name    ${manifest.name}');
  stdout.writeln('tier    ${manifest.tier.name}');
  stdout.writeln('summary ${manifest.summary}');
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
