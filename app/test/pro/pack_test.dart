import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/pro/ed25519.dart';
import 'package:vdodtor/pro/pack.dart';
import 'package:vdodtor/pro/tier.dart';

/// This file's own keypair, so nothing here depends on the shipped signing key
/// staying what it is.
final _seed = List<int>.generate(32, (i) => (i * 19 + 4) & 0xff);
final _key = Ed25519.publicKeyOf(_seed)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

const _manifest = PackManifest(
  id: 'cinema',
  name: 'Cinema',
  tier: Tier.pro,
  summary: 'Five looks for narrative work.',
  items: [
    PackItem(kind: PackContentKind.look, name: 'Vivid Print', file: 'vivid.cube'),
    PackItem(kind: PackContentKind.font, name: 'Bebas Neue', file: 'bebas.ttf'),
  ],
);

final _files = <String, Uint8List>{
  'vivid.cube': Uint8List.fromList(utf8.encode('LUT_3D_SIZE 2\n')),
  'bebas.ttf': Uint8List.fromList(List<int>.generate(300, (i) => i & 0xff)),
};

Uint8List build({
  PackManifest manifest = _manifest,
  Map<String, Uint8List>? files,
  List<int>? seed,
}) =>
    PackFile.write(
      manifest: manifest,
      files: files ?? _files,
      seed: seed ?? _seed,
    );

void main() {
  group('a pack round trip', () {
    test('comes back out as it went in', () {
      final read = PackFile.read(build(), publicKey: _key);
      expect(read.isReadable, isTrue);
      expect(read.problem, isNull);

      final pack = read.pack!;
      expect(pack.manifest.id, 'cinema');
      expect(pack.manifest.name, 'Cinema');
      expect(pack.manifest.tier, Tier.pro);
      expect(pack.manifest.summary, 'Five looks for narrative work.');
      expect(pack.manifest.items, hasLength(2));
      expect(pack.files['vivid.cube'], _files['vivid.cube']);
      expect(pack.files['bebas.ttf'], _files['bebas.ttf']);
    });

    test('keeps each kind separable', () {
      final pack = PackFile.read(build(), publicKey: _key).pack!;
      expect(
        pack.manifest.ofKind(PackContentKind.look).map((i) => i.name),
        ['Vivid Print'],
      );
      expect(
        pack.manifest.ofKind(PackContentKind.font).map((i) => i.name),
        ['Bebas Neue'],
      );
    });

    test('an empty pack is still a pack', () {
      final read = PackFile.read(
        build(
          manifest: const PackManifest(id: 'empty', name: 'Empty', tier: Tier.free),
          files: {},
        ),
        publicKey: _key,
      );
      expect(read.isReadable, isTrue);
      expect(read.pack!.present, isEmpty);
    });

    // A manifest naming something whose bytes are not in the file is content
    // missing, not a pack broken: what is there still installs.
    test('an item with no bytes is left out rather than fatal', () {
      final read = PackFile.read(
        build(files: {'vivid.cube': _files['vivid.cube']!}),
        publicKey: _key,
      );
      expect(read.isReadable, isTrue);
      expect(read.pack!.present.map((i) => i.name), ['Vivid Print']);
    });
  });

  group('a pack that will not open', () {
    test('is not a pack at all', () {
      for (final rubbish in <List<int>>[
        [],
        utf8.encode('hello'),
        List<int>.filled(200, 0),
      ]) {
        expect(
          PackFile.read(rubbish, publicKey: _key).problem,
          PackProblem.unrecognised,
          reason: '${rubbish.length} bytes',
        );
      }
    });

    // The whole reason a pack is signed: it can carry a typeface, and a
    // typeface goes to the system's font parser.
    test('was signed by somebody else', () {
      final other = Ed25519.publicKeyOf(List<int>.filled(32, 3))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(PackFile.read(build(), publicKey: other).problem,
          PackProblem.forged);
    });

    test('had a byte changed after it was signed', () {
      final bytes = build();
      // Every hundredth byte, so the sweep covers the magic, the manifest, the
      // lengths and the payload without taking a second to run.
      for (var i = 0; i < bytes.length; i += 97) {
        final tampered = Uint8List.fromList(bytes)..[i] ^= 0x01;
        expect(
          PackFile.read(tampered, publicKey: _key).isReadable,
          isFalse,
          reason: 'byte $i was not covered by the signature',
        );
      }
    });

    test('is signed and missing what a manifest needs', () {
      // Signed by us, so it gets past the signature and fails on its contents.
      final bytes = PackFile.write(
        manifest: const PackManifest(id: '', name: '', tier: Tier.free),
        files: const {},
        seed: _seed,
      );
      expect(PackFile.read(bytes, publicKey: _key).problem,
          PackProblem.incomplete);
    });

    test('stops short of the length it claims', () {
      final bytes = build();
      final truncated = Uint8List.fromList([
        ...bytes.sublist(0, bytes.length - 200),
        ...bytes.sublist(bytes.length - Ed25519.signatureBytes),
      ]);
      expect(PackFile.read(truncated, publicKey: _key).isReadable, isFalse);
    });
  });

  group('the manifest', () {
    test('survives being written and read', () {
      final again = PackManifest.parse(_manifest.write())!;
      expect(again.id, _manifest.id);
      expect(again.tier, _manifest.tier);
      expect(again.items.map((i) => i.toString()),
          _manifest.items.map((i) => i.toString()));
    });

    // A pack from a later build carrying a kind this one has never heard of
    // installs the parts it understands, rather than refusing entirely.
    test('ignores an item of a kind it does not know', () {
      final manifest = PackManifest.parse('id later\n'
          'name Later\n'
          'tier pro\n'
          'item look|Vivid Print|vivid.cube\n'
          'item template|Vlog Opener|opener.vdodtor\n');
      expect(manifest, isNotNull);
      expect(manifest!.items.map((i) => i.name), ['Vivid Print']);
    });

    // An id names a directory under Application Support and a file name
    // becomes a file in it, so neither may be a path.
    test('refuses an id that is a path', () {
      for (final id in ['..', 'a/b', '../escape', 'Cinema', '']) {
        expect(
          PackManifest.parse('id $id\nname X\ntier free'),
          isNull,
          reason: id,
        );
      }
    });

    test('refuses a file name that is a path', () {
      final manifest = PackManifest.parse('id ok\n'
          'name X\n'
          'tier free\n'
          'item look|Escape|../../../etc/passwd\n'
          'item look|Hidden|.ssh\n'
          'item look|Fine|fine.cube\n');
      expect(manifest!.items.map((i) => i.name), ['Fine']);
    });

    test('refuses a tier it has never heard of', () {
      expect(PackManifest.parse('id ok\nname X\ntier studio'), isNull);
      expect(PackManifest.parse('id ok\nname X'), isNull);
    });
  });
}
