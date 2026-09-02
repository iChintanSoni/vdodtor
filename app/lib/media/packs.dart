/// The content catalogue: every look and every face that can be picked, where
/// each came from, and what each costs.
///
/// **One rule governs the whole file, and it is worth reading twice: a locked
/// item changes what may be *chosen*, never what is *drawn*.** Every pack the
/// app can see is registered with the engine at launch whatever the tier is,
/// so a project made while somebody had Pro goes on rendering exactly as it
/// did after a subscription lapses, on a machine that never had one, and in an
/// export five years later. The gate is on the picker, and only there.
///
/// The alternative — refusing to register locked content — would mean a
/// finished film changing when a card expired. That is the same argument as
/// "no watermark, ever" and `ExportPlan.isPermitted`'s "the tier changes what
/// may be written and never what is written": the free path and the paid path
/// draw the same frame, and the tier is a yes or a no on the way in.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../pro/licence.dart' show vdodtorSigningKey;
import '../pro/pack.dart';
import '../pro/tier.dart';

import 'fonts.dart';
import 'looks.dart';

export '../pro/pack.dart'
    show PackContentKind, PackItem, PackManifest, PackProblem, PackRead;


/// What a pack file is called. A plain constant beside the catalogue because
/// the open panel wants it in a `const` list, and `PackFile` — the container —
/// is not part of what this library is for.
const String packFileExtension = PackFile.extension;

/// One thing that can be picked, and what it costs.
@immutable
final class ContentItem {
  const ContentItem({
    required this.name,
    required this.kind,
    this.tier = Tier.free,
    this.pack = '',
  });

  /// The look's name or the face's family — what a document stores, and what
  /// the picker shows.
  final String name;

  final PackContentKind kind;

  final Tier tier;

  /// The pack this came out of, for the badge's tooltip. Empty for the content
  /// built into the app and for the user's own `.cube` files.
  final String pack;

  bool get isLocked => tier.isPro;

  @override
  String toString() => '$name (${tier.name}${pack.isEmpty ? '' : ', $pack'})';
}

/// Where a pack's content goes.
///
/// An interface with one real implementation, because the catalogue has to be
/// fillable in a widget test and a widget test has no engine — the same reason
/// `BundledLooks` writes its names down instead of asking `Looks.names`.
abstract interface class ContentSink {
  void look(String name, Uint8List cube);

  void font(Uint8List data);
}

/// The engine, which is where content goes in the app.
final class EngineContentSink implements ContentSink {
  const EngineContentSink();

  @override
  void look(String name, Uint8List cube) => Looks.register(name, cube);

  @override
  void font(Uint8List data) => TextFonts.register(data);
}

/// Every pack this installation can see, and the merged catalogue over them.
abstract final class ContentPacks {
  /// The packs that ship inside the app.
  ///
  /// Shipped as `.vdpack` files rather than as loose assets so that there is
  /// exactly one road into the catalogue: the pack the app was built with and
  /// the pack somebody installs next year are read by the same function,
  /// verified by the same signature and locked by the same tier. A second
  /// mechanism for built-in content would be a second mechanism to keep in
  /// step.
  static const bundled = <String>['assets/packs/cinema.vdpack'];

  /// Where installed packs are kept, beside the app's other private state.
  ///
  /// The **signed container** is what is stored, not its unpacked contents:
  /// loose files on disk are files anybody can replace, and re-reading the
  /// `.vdpack` at every launch means the signature is checked every time
  /// rather than once, on a machine where the pack has been sitting for a
  /// year. It also makes uninstalling one file.
  static Directory libraryOf(Directory support) =>
      Directory('${support.path}/Packs');

  static final List<ContentPack> _packs = [];

  static Directory? _installedIn;

  /// Where [load] read installed packs from, once it has run.
  ///
  /// Remembered rather than passed around because the catalogue is already
  /// one per process — the engine's own look and font registries are, and this
  /// is the list of what went into them. It is what lets the Pro sheet offer
  /// to install a pack without every widget between here and there carrying a
  /// directory it has no other use for. Null until [load] has been given one,
  /// which is every widget test that does not care.
  static Directory? get installedIn => _installedIn;

  /// Every pack that loaded, in the order they were read.
  static List<PackManifest> get packs =>
      List.unmodifiable([for (final pack in _packs) pack.manifest]);

  /// Every look that can be picked right now, in the order a picker should
  /// offer them: the app's own first, then the user's, then the packs'.
  ///
  /// A pack naming a look that already exists does not get a second entry —
  /// the engine keeps the first registration under a name, so a duplicate in
  /// the list would be an entry that picked something else.
  static List<ContentItem> get looks => _merged(
        free: BundledLooks.available,
        kind: PackContentKind.look,
      );

  /// Every typeface, the same way.
  static List<ContentItem> get faces => _merged(
        free: BundledFonts.families,
        kind: PackContentKind.font,
      );

  static List<ContentItem> _merged({
    required List<String> free,
    required PackContentKind kind,
  }) {
    final items = <ContentItem>[
      for (final name in free) ContentItem(name: name, kind: kind),
    ];
    final taken = {for (final item in items) item.name};
    for (final pack in _packs) {
      for (final item in pack.present.where((i) => i.kind == kind)) {
        if (!taken.add(item.name)) continue;
        items.add(ContentItem(
          name: item.name,
          kind: kind,
          tier: pack.manifest.tier,
          pack: pack.manifest.name,
        ));
      }
    }
    return List.unmodifiable(items);
  }

  /// What a look costs. [Tier.free] for anything no pack claims, which
  /// includes every look the app was built with and every one the user loaded
  /// themselves.
  static Tier tierOfLook(String name) => _tierOf(name, PackContentKind.look);

  /// What a face costs.
  static Tier tierOfFace(String family) =>
      _tierOf(family, PackContentKind.font);

  static Tier _tierOf(String name, PackContentKind kind) {
    for (final item in _merged(
      free: kind == PackContentKind.look
          ? BundledLooks.available
          : BundledFonts.families,
      kind: kind,
    )) {
      if (item.name == name) return item.tier;
    }
    // A look a document names and this installation does not have is not
    // locked — it is missing, which the picker already shows and the engine
    // already draws around.
    return Tier.free;
  }

  /// Reads every pack the app ships and every one installed, and registers
  /// what they contain.
  ///
  /// Awaited before the first project opens, for `BundledLooks.load`'s reason:
  /// a clip naming a look that has not been registered yet renders ungraded,
  /// and registering it afterwards would not redraw the frame.
  ///
  /// A pack that will not verify is **skipped rather than thrown**. The
  /// installed ones live in a folder the user can drop files into, and one bad
  /// file must not stop the app launching.
  static Future<void> load({
    Directory? installed,
    ContentSink sink = const EngineContentSink(),
    List<String> bundledAssets = bundled,
    String publicKey = vdodtorSigningKey,
  }) async {
    _packs.clear();
    _installedIn = installed;
    for (final asset in bundledAssets) {
      try {
        final data = await rootBundle.load(asset);
        _adopt(data.buffer.asUint8List(), sink, publicKey);
      } on FlutterError {
        // A pack declared in this file and not in the bundle is a build
        // mistake, and one an assert would only catch in debug. Leaving it out
        // is what a release should do; the analyzer and the asset test are
        // what catch it before then.
        continue;
      }
    }

    if (installed == null || !installed.existsSync()) return;
    final files = installed
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.${PackFile.extension}'))
        .toList()
      // Sorted, so two launches read them in the same order: the filesystem's
      // order is not an order anybody chose.
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      try {
        _adopt(await file.readAsBytes(), sink, publicKey);
      } on FileSystemException {
        continue;
      }
    }
  }

  static void _adopt(Uint8List bytes, ContentSink sink, String publicKey) {
    final read = PackFile.read(bytes, publicKey: publicKey);
    final pack = read.pack;
    if (pack == null) return;
    if (_packs.any((p) => p.manifest.id == pack.manifest.id)) return;

    for (final item in pack.present) {
      try {
        switch (item.kind) {
          case PackContentKind.look:
            sink.look(item.name, pack.files[item.file]!);
          case PackContentKind.font:
            sink.font(pack.files[item.file]!);
        }
      } on Exception {
        // One unreadable `.cube` in a pack of five should cost that one look,
        // not the pack — and certainly not the launch.
        continue;
      }
    }
    _packs.add(pack);
  }

  /// Copies a `.vdpack` into [into] and folds it into the catalogue.
  ///
  /// Verified *before* it is copied, so a file that is not one of ours leaves
  /// nothing behind to fail again at every launch — the rule
  /// `BundledLooks.import` follows for a `.cube`.
  ///
  /// The content it carries registers immediately, so the picker has it
  /// without a restart. Replacing an installed pack with a newer one of the
  /// same id needs a restart to take effect, and says so, because the engine's
  /// catalogue keeps the first registration under a name and there is no way
  /// to take one back.
  static Future<PackRead> install(
    String path, {
    required Directory into,
    ContentSink sink = const EngineContentSink(),
    String publicKey = vdodtorSigningKey,
  }) async {
    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } on FileSystemException {
      return const PackRead.rejected(PackProblem.unrecognised);
    }

    final read = PackFile.read(bytes, publicKey: publicKey);
    final pack = read.pack;
    if (pack == null) return read;

    await into.create(recursive: true);
    await File('${into.path}/${pack.manifest.id}.${PackFile.extension}')
        .writeAsBytes(bytes, flush: true);
    _adopt(bytes, sink, publicKey);
    return read;
  }

  /// Removes an installed pack.
  ///
  /// It leaves the catalogue for this run alone, deliberately: content cannot
  /// be un-registered, and pretending otherwise would mean a picker offering
  /// looks the engine would draw and a document that could name one of them.
  /// The pack is gone at the next launch, and the sheet says so.
  static Future<void> uninstall(String id, {required Directory from}) async {
    final file = File('${from.path}/$id.${PackFile.extension}');
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Gone either way, as far as the caller is concerned.
    }
  }

  /// True for a pack that has been removed but is still registered, which is
  /// every pack removed since this launch.
  static bool isInstalled(String id, {required Directory from}) =>
      File('${from.path}/$id.${PackFile.extension}').existsSync();

  /// Forgets every pack. Only for tests, which need a catalogue that does not
  /// carry over from the last one.
  @visibleForTesting
  static void reset() {
    _packs.clear();
    _installedIn = null;
  }
}
