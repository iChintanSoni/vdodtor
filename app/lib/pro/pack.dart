/// What a content pack is: a manifest, some files, and a signature over both.
///
/// A pack is how vdodtor gets more of the things a clip can *wear* — looks and
/// typefaces today — without a new build. One file, `.vdpack`, holding what it
/// contains and what it costs, so that the premium packs the brief sells (§5)
/// and the pack drops PLAN.md lists after v1 travel the same road as the ones
/// shipped inside the app.
///
/// **Why a pack is signed, when a licence key already is.** A `.cube` the user
/// loads by hand is parsed by `vd_lut.c`, which is forty lines of our own
/// arithmetic. A pack can carry a *typeface*, and a typeface is handed to Core
/// Text — a font parser is one of the larger attack surfaces on the machine,
/// and "download this file and drop it on the editor" is exactly the shape of
/// the trick you would use to reach it. So a pack has to be one of ours. This
/// is not the gate on Pro content: the tier decides that, and it is a decision
/// about money. This is a decision about whose bytes reach a parser.
///
/// It leaves the user's own `.cube` route alone, deliberately: one file, one
/// format we wrote the reader for, no signature, exactly as it was.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'ed25519.dart';
import 'licence.dart' show vdodtorSigningKey;
import 'tier.dart';

/// What a pack can carry.
///
/// Two, and not the four PLAN.md's item names. A pack is *data*, and these are
/// the two kinds of content the engine can be handed at runtime: a `.cube`
/// through `vd_lut_register` and a font through `vd_text_register_font`.
///
/// **Transitions** cannot join them yet because a transition is a
/// `VdTransitionPreset` — an index into code in `vd_transition.c`, not a file —
/// so a pack could only ever name one that already exists. Carrying a new one
/// means giving transitions parameters first, which is engine work and not
/// plumbing. **Templates** cannot join because there is nothing to carry: a
/// template would be a project file used as a starting point, and "new from
/// template" does not exist. Both are named here rather than left out so that
/// the next person reads why, and both are appended when they arrive — this
/// enum crosses no boundary and is stored nowhere, so adding to it is free.
enum PackContentKind {
  look('look'),
  font('font');

  const PackContentKind(this.key);

  /// What the manifest writes. Spelled out rather than taken from [name] so
  /// that renaming the Dart identifier cannot silently invalidate every pack
  /// ever built.
  final String key;

  static PackContentKind? named(String key) {
    for (final kind in values) {
      if (kind.key == key) return kind;
    }
    return null;
  }
}

/// One thing a pack contains.
@immutable
final class PackItem {
  const PackItem({
    required this.kind,
    required this.name,
    required this.file,
  });

  final PackContentKind kind;

  /// What the picker shows and, for a look, what a clip stores. For a font it
  /// is the family name — declared here as well as living inside the file, for
  /// the reason `BundledFonts.faces` declares its families: a picker has to
  /// list faces before an engine exists.
  final String name;

  /// The entry in the pack this item's bytes are under.
  final String file;

  @override
  String toString() => '${kind.key}|$name|$file';
}

/// What a pack says about itself.
@immutable
final class PackManifest {
  const PackManifest({
    required this.id,
    required this.name,
    required this.tier,
    this.summary = '',
    this.items = const [],
  });

  /// Stable, filename-safe, and the identity: a pack installed twice under two
  /// names is one pack, and the second replaces the first.
  final String id;

  /// What the sheet calls it.
  final String name;

  /// What it costs. On the pack rather than on each item, because a pack is
  /// the unit somebody buys and a half-locked pack would need explaining.
  final Tier tier;

  final String summary;

  final List<PackItem> items;

  Iterable<PackItem> ofKind(PackContentKind kind) =>
      items.where((item) => item.kind == kind);

  /// The manifest as it is written into a pack.
  ///
  /// A flat `key value` list, and `item` repeated once per thing carried. The
  /// same shape a licence payload has, for the same reason: what gets signed
  /// is bytes, and JSON invites a re-encode that two writers can disagree
  /// about.
  String write() => [
        'id $id',
        'name $name',
        'tier ${tier.name}',
        if (summary.isNotEmpty) 'summary $summary',
        for (final item in items) 'item $item',
      ].join('\n');

  /// Reads a manifest, or null if it is missing something a pack needs.
  static PackManifest? parse(String text) {
    final fields = <String, String>{};
    final items = <PackItem>[];

    for (final line in text.split('\n')) {
      final space = line.indexOf(' ');
      if (space <= 0) continue;
      final key = line.substring(0, space);
      final value = line.substring(space + 1).trim();
      if (key == 'item') {
        final item = _parseItem(value);
        // A pack naming a kind this build has never heard of is a pack from a
        // later version: the items it *can* read still install, and the rest
        // are left alone rather than making the whole file unreadable. The
        // signature is over the file either way, so nothing has been skipped
        // that was not signed.
        if (item != null) items.add(item);
        continue;
      }
      fields.putIfAbsent(key, () => value);
    }

    final id = fields['id'];
    final name = fields['name'];
    final tier = _tierNamed(fields['tier']);
    if (id == null || id.isEmpty || name == null || tier == null) return null;
    if (!_isSafeId(id)) return null;

    return PackManifest(
      id: id,
      name: name,
      tier: tier,
      summary: fields['summary'] ?? '',
      items: List.unmodifiable(items),
    );
  }

  static PackItem? _parseItem(String value) {
    final parts = value.split('|');
    if (parts.length != 3) return null;
    final kind = PackContentKind.named(parts[0]);
    if (kind == null) return null;
    if (parts[1].isEmpty || parts[2].isEmpty) return null;
    if (!_isSafeFile(parts[2])) return null;
    return PackItem(kind: kind, name: parts[1], file: parts[2]);
  }

  /// An id becomes a directory name under Application Support, so it may not
  /// be a path. `..` and a slash are the whole of the danger and both are
  /// excluded by only allowing what an id is actually for.
  static bool _isSafeId(String id) =>
      id.length <= 64 && RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(id);

  /// Likewise a file name inside the pack, which becomes a file on disk. No
  /// separators, no leading dot, nothing clever.
  static bool _isSafeFile(String file) =>
      file.length <= 128 &&
      !file.contains('/') &&
      !file.contains(r'\') &&
      !file.startsWith('.') &&
      file.trim() == file;

  static Tier? _tierNamed(String? name) {
    for (final tier in Tier.values) {
      if (tier.name == name) return tier;
    }
    return null;
  }
}

/// A pack, read.
@immutable
final class ContentPack {
  const ContentPack({required this.manifest, required this.files});

  final PackManifest manifest;

  /// The bytes each entry in the manifest names.
  final Map<String, Uint8List> files;

  /// The items whose file is actually in here. A manifest that names one that
  /// is not is missing content rather than broken: the rest still installs.
  Iterable<PackItem> get present =>
      manifest.items.where((item) => files.containsKey(item.file));
}

/// Why a `.vdpack` would not open.
enum PackProblem {
  /// Not a pack: the wrong magic, or truncated part-way through.
  unrecognised('That is not a vdodtor content pack.'),

  /// A pack, and not one of ours. Packs are signed because they can carry a
  /// typeface, and a typeface goes to the system's font parser.
  forged('That pack is not signed by vdodtor, so it will not be installed.'),

  /// Signed by us and missing something a pack needs.
  incomplete('That pack needs a newer version of vdodtor to open.');

  const PackProblem(this.message);

  final String message;
}

/// What reading a pack produced.
@immutable
final class PackRead {
  const PackRead({this.pack, this.problem});

  const PackRead.rejected(PackProblem problem) : this(problem: problem);

  final ContentPack? pack;
  final PackProblem? problem;

  bool get isReadable => pack != null;
}

/// The `.vdpack` container.
///
/// ```
///   magic      8    "VDPACK1\n"
///   u32             manifest length
///   bytes           manifest, UTF-8
///   u32             number of files
///   per file:  u16  name length
///              bytes name, UTF-8
///              u32  data length
///              bytes data
///   64              Ed25519 signature over everything above
/// ```
///
/// Big-endian throughout, because a format written down is a format read the
/// same way on the machine that did not write it. Deliberately not a zip: an
/// archive library is a dependency in the path of installing something the
/// user paid for, and a hundred lines of length-prefixed records is a thing
/// this repository can read in five years without one.
abstract final class PackFile {
  static const List<int> magic = [0x56, 0x44, 0x50, 0x41, 0x43, 0x4b, 0x31, 0x0a];

  /// The extension, and what an open panel filters on.
  static const String extension = 'vdpack';

  /// A pack may not be larger than this. Everything inside is read into
  /// memory, and a length field claiming four gigabytes should be refused by
  /// arithmetic rather than by the allocator.
  static const int maxBytes = 64 * 1024 * 1024;

  /// Reads and verifies. Never throws: every byte here came out of a file
  /// somebody was handed.
  static PackRead read(
    List<int> bytes, {
    String publicKey = vdodtorSigningKey,
  }) {
    if (bytes.length < magic.length + Ed25519.signatureBytes) {
      return const PackRead.rejected(PackProblem.unrecognised);
    }
    if (bytes.length > maxBytes) {
      return const PackRead.rejected(PackProblem.unrecognised);
    }
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        return const PackRead.rejected(PackProblem.unrecognised);
      }
    }

    final split = bytes.length - Ed25519.signatureBytes;
    final signed = bytes.sublist(0, split);
    final signature = bytes.sublist(split);

    final trusted = Ed25519.keyFromHex(publicKey);
    if (trusted == null) {
      return const PackRead.rejected(PackProblem.forged);
    }

    // Signature first, over the bytes as they arrived — the rule the licence
    // reader follows, and here it is load-bearing twice over: nothing below
    // this line parses anything an attacker chose.
    if (!Ed25519.verify(
      publicKey: trusted,
      message: signed,
      signature: signature,
    )) {
      return const PackRead.rejected(PackProblem.forged);
    }

    final reader = _Reader(signed, magic.length);
    try {
      final manifest = PackManifest.parse(
          utf8.decode(reader.bytes(reader.u32()), allowMalformed: true));
      if (manifest == null) {
        return const PackRead.rejected(PackProblem.incomplete);
      }

      final files = <String, Uint8List>{};
      final count = reader.u32();
      for (var i = 0; i < count; i++) {
        final name = utf8.decode(reader.bytes(reader.u16()), allowMalformed: true);
        files[name] = reader.bytes(reader.u32());
      }

      return PackRead(pack: ContentPack(manifest: manifest, files: files));
    } on FormatException {
      return const PackRead.rejected(PackProblem.unrecognised);
    }
  }

  /// Writes one. Used by `app/tool/pack.dart`; the app only ever reads.
  static Uint8List write({
    required PackManifest manifest,
    required Map<String, Uint8List> files,
    required List<int> seed,
  }) {
    final body = BytesBuilder(copy: false)..add(magic);
    final text = utf8.encode(manifest.write());
    body
      ..add(_u32(text.length))
      ..add(text)
      ..add(_u32(files.length));
    files.forEach((name, data) {
      final key = utf8.encode(name);
      body
        ..add(_u16(key.length))
        ..add(key)
        ..add(_u32(data.length))
        ..add(data);
    });

    final signed = body.takeBytes();
    return Uint8List(signed.length + Ed25519.signatureBytes)
      ..setRange(0, signed.length, signed)
      ..setRange(signed.length, signed.length + Ed25519.signatureBytes,
          Ed25519.sign(seed: seed, message: signed));
  }
}

final class _Reader {
  _Reader(this._bytes, this._at);

  final List<int> _bytes;
  int _at;

  int u16() {
    _need(2);
    final value = (_bytes[_at] << 8) | _bytes[_at + 1];
    _at += 2;
    return value;
  }

  int u32() {
    _need(4);
    final value = (_bytes[_at] << 24) |
        (_bytes[_at + 1] << 16) |
        (_bytes[_at + 2] << 8) |
        _bytes[_at + 3];
    _at += 4;
    return value;
  }

  Uint8List bytes(int length) {
    _need(length);
    final out = Uint8List.fromList(_bytes.sublist(_at, _at + length));
    _at += length;
    return out;
  }

  /// A length that runs off the end is a truncated file, not an exception the
  /// caller has to think about — the one catch in [PackFile.read] turns every
  /// one of these into "not a pack".
  void _need(int count) {
    if (count < 0 || _at + count > _bytes.length) {
      throw const FormatException('pack ends part-way through');
    }
  }
}

List<int> _u16(int value) => [(value >> 8) & 0xff, value & 0xff];

List<int> _u32(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];
