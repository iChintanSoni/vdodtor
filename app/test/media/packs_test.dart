import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/fonts.dart';
import 'package:vdodtor/media/looks.dart';
import 'package:vdodtor/media/packs.dart';
import 'package:vdodtor/pro/ed25519.dart';
import 'package:vdodtor/pro/pack.dart';
import 'package:vdodtor/pro/tier.dart';

/// Where content goes when there is no engine to send it to.
final class _Recorder implements ContentSink {
  final looks = <String, Uint8List>{};
  final fonts = <Uint8List>[];

  @override
  void look(String name, Uint8List cube) => looks[name] = cube;

  @override
  void font(Uint8List data) => fonts.add(data);
}

/// A sink that refuses one particular look, standing in for a `.cube` the
/// engine will not parse.
final class _PickyRecorder extends _Recorder {
  _PickyRecorder(this.refuse);

  final String refuse;

  @override
  void look(String name, Uint8List cube) {
    if (name == refuse) throw Exception('not a usable .cube file');
    super.look(name, cube);
  }
}

/// This file signs its own packs, so nothing here depends on the shipped
/// signing key staying what it is — except the tests about the *shipped* pack,
/// which are exactly the ones that should.
final _seed = List<int>.generate(32, (i) => (i * 23 + 6) & 0xff);
final _key = Ed25519.publicKeyOf(_seed)
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

Uint8List pack({
  String id = 'extra',
  String name = 'Extra',
  Tier tier = Tier.pro,
  List<PackItem> items = const [
    PackItem(kind: PackContentKind.look, name: 'Extra Look', file: 'a.cube'),
  ],
  Map<String, Uint8List>? files,
  List<int>? seed,
}) =>
    PackFile.write(
      manifest: PackManifest(id: id, name: name, tier: tier, items: items),
      files: files ??
          {
            for (final item in items)
              item.file: Uint8List.fromList([1, 2, 3, item.name.length])
          },
      seed: seed ?? _seed,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    ContentPacks.reset();
    dir = await Directory.systemTemp.createTemp('vdodtor-packs');
  });

  tearDown(() async {
    ContentPacks.reset();
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  group('the shipped pack', () {
    test('is in the bundle, signed by us, and full of looks', () async {
      final sink = _Recorder();
      await ContentPacks.load(sink: sink);

      expect(ContentPacks.packs.map((p) => p.id), contains('cinema'));
      final cinema =
          ContentPacks.packs.firstWhere((p) => p.id == 'cinema');
      expect(cinema.tier, Tier.pro);
      expect(cinema.name, 'Cinema');
      expect(cinema.items, hasLength(5));

      // Registered, tier or no tier: a locked look still has to draw for
      // anybody whose project already names it.
      for (final item in cinema.items) {
        expect(sink.looks, contains(item.name), reason: item.name);
      }
    });

    test('is offered after the free looks, wearing its tier', () async {
      await ContentPacks.load(sink: _Recorder());

      final looks = ContentPacks.looks;
      final free = looks.where((l) => l.tier == Tier.free).map((l) => l.name);
      final locked = looks.where((l) => l.isLocked).map((l) => l.name);

      expect(free, containsAll(BundledLooks.names));
      expect(locked, contains('Cyanotype'));
      // Everything free comes first, so the picker does not open on a list
      // that starts with things the user cannot choose.
      expect(
        looks.map((l) => l.isLocked).toList(),
        [...List.filled(free.length, false), ...List.filled(locked.length, true)],
      );
    });

    test('says which pack a locked look came from', () async {
      await ContentPacks.load(sink: _Recorder());
      final item =
          ContentPacks.looks.firstWhere((l) => l.name == 'Neon Night');
      expect(item.pack, 'Cinema');
      expect(item.tier, Tier.pro);
    });
  });

  group('what a look costs', () {
    test('is free for everything built in and everything imported', () async {
      await ContentPacks.load(sink: _Recorder());
      for (final name in BundledLooks.names) {
        expect(ContentPacks.tierOfLook(name), Tier.free, reason: name);
      }
    });

    test('is Pro for a look a Pro pack brought', () async {
      await ContentPacks.load(sink: _Recorder());
      expect(ContentPacks.tierOfLook('Golden Hour'), Tier.pro);
    });

    // Missing is not locked: a project naming a look this installation does
    // not have already draws ungraded, and calling that a purchase would send
    // somebody to a shop that cannot help them.
    test('is free for a look nobody has ever heard of', () async {
      await ContentPacks.load(sink: _Recorder());
      expect(ContentPacks.tierOfLook('Kodak 2383'), Tier.free);
    });

    test('is free for every face, because no pack sells one yet', () async {
      await ContentPacks.load(sink: _Recorder());
      for (final family in BundledFonts.families) {
        expect(ContentPacks.tierOfFace(family), Tier.free);
      }
    });
  });

  group('installing', () {
    test('copies the pack in and offers its content at once', () async {
      final sink = _Recorder();
      await ContentPacks.load(
          installed: dir, sink: sink, bundledAssets: const [], publicKey: _key);
      expect(ContentPacks.packs, isEmpty);

      final file = File('${dir.path}/from-the-web.vdpack')
        ..writeAsBytesSync(pack());
      final read = await ContentPacks.install(file.path,
          into: dir, sink: sink, publicKey: _key);

      expect(read.isReadable, isTrue);
      expect(ContentPacks.packs.map((p) => p.id), ['extra']);
      expect(sink.looks, contains('Extra Look'));
      expect(ContentPacks.tierOfLook('Extra Look'), Tier.pro);
      // Stored under its id, so installing it twice replaces rather than
      // accumulates.
      expect(File('${dir.path}/extra.vdpack').existsSync(), isTrue);
    });

    test('leaves nothing behind when the pack is not ours', () async {
      final sink = _Recorder();
      final file = File('${dir.path}/bad.vdpack')
        ..writeAsBytesSync(pack(seed: List<int>.filled(32, 7)));

      final read = await ContentPacks.install(file.path,
          into: dir, sink: sink, publicKey: _key);

      expect(read.problem, PackProblem.forged);
      expect(ContentPacks.packs, isEmpty);
      expect(sink.looks, isEmpty);
      expect(File('${dir.path}/extra.vdpack').existsSync(), isFalse);
    });

    test('refuses a file that is not there', () async {
      final read = await ContentPacks.install('${dir.path}/nothing.vdpack',
          into: dir, sink: _Recorder(), publicKey: _key);
      expect(read.problem, PackProblem.unrecognised);
    });

    test('reads what is installed at the next launch', () async {
      File('${dir.path}/extra.vdpack').writeAsBytesSync(pack());
      final sink = _Recorder();
      await ContentPacks.load(
          installed: dir, sink: sink, bundledAssets: const [], publicKey: _key);

      expect(ContentPacks.packs.map((p) => p.id), ['extra']);
      expect(sink.looks, contains('Extra Look'));
    });

    // The folder is one the user can drop files into, so a bad one must cost
    // that pack and nothing else.
    test('skips a pack that will not verify and loads the rest', () async {
      File('${dir.path}/bad.vdpack')
          .writeAsBytesSync(pack(id: 'bad', seed: List<int>.filled(32, 7)));
      File('${dir.path}/rubbish.vdpack').writeAsBytesSync(
          Uint8List.fromList(List<int>.filled(500, 0x41)));
      File('${dir.path}/good.vdpack').writeAsBytesSync(pack(id: 'good'));

      final sink = _Recorder();
      await ContentPacks.load(
          installed: dir, sink: sink, bundledAssets: const [], publicKey: _key);

      expect(ContentPacks.packs.map((p) => p.id), ['good']);
    });

    test('one unreadable look costs that look, not the pack', () async {
      File('${dir.path}/two.vdpack').writeAsBytesSync(pack(items: const [
        PackItem(kind: PackContentKind.look, name: 'Bad', file: 'a.cube'),
        PackItem(kind: PackContentKind.look, name: 'Good', file: 'b.cube'),
      ]));

      final sink = _PickyRecorder('Bad');
      await ContentPacks.load(
          installed: dir, sink: sink, bundledAssets: const [], publicKey: _key);

      expect(ContentPacks.packs.map((p) => p.id), ['extra']);
      expect(sink.looks.keys, ['Good']);
    });

    test('a name already taken is not offered twice', () async {
      File('${dir.path}/clash.vdpack').writeAsBytesSync(pack(items: [
        PackItem(
            kind: PackContentKind.look,
            name: BundledLooks.names.first,
            file: 'a.cube'),
      ]));
      await ContentPacks.load(
          installed: dir,
          sink: _Recorder(),
          bundledAssets: const [],
          publicKey: _key);

      final matching = ContentPacks.looks
          .where((l) => l.name == BundledLooks.names.first);
      expect(matching, hasLength(1));
      // And it is the free one, because the engine keeps the first
      // registration under a name.
      expect(matching.single.tier, Tier.free);
    });

    test('removing one takes the file and leaves this run alone', () async {
      File('${dir.path}/extra.vdpack').writeAsBytesSync(pack());
      final sink = _Recorder();
      await ContentPacks.load(
          installed: dir, sink: sink, bundledAssets: const [], publicKey: _key);

      await ContentPacks.uninstall('extra', from: dir);

      expect(File('${dir.path}/extra.vdpack').existsSync(), isFalse);
      expect(ContentPacks.isInstalled('extra', from: dir), isFalse);
      // Still registered: content cannot be taken back out of the engine, and
      // a picker offering less than the engine draws would be a picker that
      // lied.
      expect(ContentPacks.packs.map((p) => p.id), ['extra']);
    });
  });

  test('the signature is checked at every launch, not once at install',
      () async {
    File('${dir.path}/extra.vdpack').writeAsBytesSync(pack());
    await ContentPacks.load(
        installed: dir,
        sink: _Recorder(),
        bundledAssets: const [],
        publicKey: _key);
    expect(ContentPacks.packs, hasLength(1));

    // Somebody edits the installed file after it was let in. Storing the
    // signed container rather than its unpacked contents is what makes this
    // catchable at all.
    final bytes = File('${dir.path}/extra.vdpack').readAsBytesSync();
    bytes[bytes.length ~/ 2] ^= 0x01;
    File('${dir.path}/extra.vdpack').writeAsBytesSync(bytes);

    ContentPacks.reset();
    await ContentPacks.load(
        installed: dir,
        sink: _Recorder(),
        bundledAssets: const [],
        publicKey: _key);
    expect(ContentPacks.packs, isEmpty);
  });

  test('the same pack twice is one pack', () async {
    File('${dir.path}/a.vdpack').writeAsBytesSync(pack());
    File('${dir.path}/b.vdpack').writeAsBytesSync(pack());
    await ContentPacks.load(
        installed: dir,
        sink: _Recorder(),
        bundledAssets: const [],
        publicKey: _key);
    expect(ContentPacks.packs, hasLength(1));
  });
}
