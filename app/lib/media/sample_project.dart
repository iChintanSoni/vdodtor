import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../engine/media_probe.dart';
import '../model/clip.dart';
import '../model/ids.dart';
import '../model/project.dart';
import '../model/time.dart';
import '../model/track.dart';
import 'file_access.dart';
import 'fonts.dart';
import 'looks.dart';
import 'media_import.dart';

/// The project a first launch can open instead of an empty one.
///
/// An editor's first window is the hardest one: nothing is on the timeline, so
/// nothing on screen does anything, and every control is greyed out until the
/// user has already found their own footage and imported it. The sample is the
/// answer to that — a fifteen-second edit that is already cut, already graded
/// and already has words on it, so the first thing anybody sees is an editor
/// with something in it that they can take apart.
///
/// **It is code rather than a project file.** A `.vdo` shipped as an asset
/// would carry absolute paths that are wrong on every machine but the one that
/// wrote it, and it would go stale the moment the document format moved —
/// silently, because nothing reads a sample project until a stranger opens it.
/// Built from the model, it is exactly as current as the model is, and the
/// thirty lines below are a thing a reviewer can argue with. That is
/// `tools/make_luts.dart`'s argument about the looks, applied to a document.
///
/// The consequence worth stating: this is **not** a template system. A
/// template would be a project file used as a starting point — what
/// `PackContentKind` names and defers — and building one now, for one
/// template, would be a mechanism with no second user. When a pack carries
/// templates the mechanism arrives with the thing that needs it.
abstract final class SampleProject {
  /// What the project is called, and so what its file is called.
  static const name = 'Sample project';

  /// Where the footage is copied to, under the project library — so it sits
  /// beside the project that uses it, in the folder the user already knows
  /// their projects are in.
  static const mediaFolderName = 'Sample Media';

  /// The three shots, in the order they are cut together.
  static const shots = ['sunrise.mp4', 'tide.mp4', 'dusk.mp4'];

  /// The bed under them.
  static const bed = 'chord-bed.m4a';

  /// Every file that has to be in the bundle for [stage] to work, as asset
  /// keys. Written out so a test can assert the bundle actually holds them:
  /// a sample whose footage was left out of `pubspec.yaml` is an empty
  /// timeline on somebody's first launch, and nothing else would notice.
  static List<String> get assetKeys =>
      [for (final f in [...shots, bed]) 'assets/sample/$f'];

  /// True for the project this file made. Used by the app shell to decide
  /// whether the tour has anything to point at.
  static bool isSample(Project project) => project.name == name;

  /// Copies the bundled footage into `<library>/Sample Media`, and hands back
  /// where it landed.
  ///
  /// Copied rather than referred to, for the reason `BundledLooks.install`
  /// copies a `.cube`: a file inside the app bundle is readable — the sandbox
  /// grants it for being the app's own — but it cannot be bookmarked at all,
  /// so a project pointing into the bundle would be one whose media the
  /// importer could never mint a scope for. The library is granted whole by
  /// entitlement, so what lands there behaves exactly like the user's own
  /// footage, which is the point: the sample must not be a special case the
  /// rest of the app has to know about.
  ///
  /// It is also **the user's** once it is there. They can keep it, reuse it,
  /// or throw it away — and if they throw it away the sample project reports
  /// its media as missing, like any other project whose footage moved, rather
  /// than silently reappearing.
  static Future<List<File>> stage(Directory library) async {
    final into = Directory('${library.path}/$mediaFolderName');
    await into.create(recursive: true);

    final staged = <File>[];
    for (final key in assetKeys) {
      final file = File('${into.path}/${key.split('/').last}');
      // Not overwritten if it is already there: somebody who graded the
      // sample's footage in another project should not have it replaced
      // under them by opening a second sample.
      if (!file.existsSync()) {
        final data = await rootBundle.load(key);
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      staged.add(file);
    }
    return staged;
  }

  /// Builds the edit over [media], which is what [stage] returned.
  ///
  /// Through the real importer, the real probe and the real bookmarks, so the
  /// sample is a project somebody could have made rather than one only this
  /// function can produce — and so the lengths below come from the files
  /// instead of from a constant that would be wrong the day the footage is
  /// regenerated.
  ///
  /// The store it edits through is a scratch one. What is returned is the
  /// document; the undo stack that made it is dropped on the floor, because
  /// the first ⌘Z in a project somebody just opened must not start undoing
  /// the project.
  static Future<Project> build({
    required List<File> media,
    required ProjectFormat format,
    IdGen? ids,
    MediaProber prober = const EngineMediaProber(),
    FileAccess access = const SystemFileAccess(),
  }) async {
    final gen = ids ?? IdGen();
    final store = DocumentStore(Project.empty(
      id: gen.next('pr-'),
      name: name,
      format: format,
      mainTrackId: gen.next('tr-'),
      audioTrackId: gen.next('tr-'),
    ));

    try {
      await MediaImporter(prober: prober, access: access, ids: gen).import(
        store,
        [for (final file in media) GrantedFile(path: file.path)],
      );
      _arrange(store, gen);
      return store.project;
    } finally {
      store.dispose();
    }
  }

  /// Turns three clips in a row into something that looks edited.
  ///
  /// Everything here is a value somebody could have set in the inspector, and
  /// deliberately so: the sample teaches by being a project, and a project
  /// that used a feature the panels cannot reach would teach the wrong thing.
  static void _arrange(DocumentStore store, IdGen ids) {
    final main = store.project.mainTrack;
    if (main.clips.length < shots.length) return;

    final second = main.clips[1];
    final third = main.clips[2];

    // Two joins rather than two of the same join: the point being made is that
    // a cut is a choice, and two dissolves would read as "this is what cuts
    // look like here".
    store.run(SetClipTransition(
      second.id,
      ClipTransition(preset: TransitionPreset.dissolve, duration: _ticks(0.7)),
    ));
    store.run(SetClipTransition(
      third.id,
      ClipTransition(preset: TransitionPreset.wipe, duration: _ticks(0.7)),
    ));

    // The film opens out of black and closes back into it, which is what makes
    // fifteen seconds read as a piece rather than as three clips.
    store.run(SetClipAnimation(
      main.clips.first.id,
      ClipAnimation(inPreset: AnimationPreset.fade, inDuration: _ticks(0.8)),
    ));
    store.run(SetClipAnimation(
      third.id,
      ClipAnimation(outPreset: AnimationPreset.fade, outDuration: _ticks(1.2)),
    ));

    // A look on the middle shot and on neither of its neighbours, so the first
    // thing anybody learns about grading is that it belongs to a clip. At less
    // than full strength for the same reason the inspector opens the slider
    // there: a look is a starting point.
    store.run(SetClipColor(
      second.id,
      const ClipColor(
        contrast: 0.08,
        look: look,
        lookStrength: 0.65,
      ),
    ));

    _addTitles(store, ids);
    _fadeTheBed(store);
  }

  /// A title, a rule under it and a line of small type: the arrangement
  /// anybody recognises, made of the two things the app draws.
  ///
  /// Three lanes because all three are on screen together and a lane holds no
  /// overlaps — which is the rule the editor's own ⌘T follows, so a user who
  /// adds a fourth caption here gets a fourth lane and nothing surprising.
  /// The closing caption goes back on the first lane: it does not overlap the
  /// title, so it needs no lane of its own.
  static void _addTitles(DocumentStore store, IdGen ids) {
    final project = store.project;
    final end = project.duration;
    if (end.raw <= 0) return;

    final title = Clip.caption(
      id: ids.next('c-'),
      start: _ticks(0.9),
      duration: _ticks(3.3),
      text: const ClipText(
        text: 'vdodtor',
        font: 'Anton',
        size: 0.13,
        letterSpacing: 0.02,
        shadowColor: 0x59000000,
        shadowOffsetY: 0.05,
        shadowBlur: 0.10,
      ),
      transform: const ClipTransform(offsetY: -0.07),
      animation: ClipAnimation(
        inPreset: AnimationPreset.pop,
        inDuration: _ticks(0.5),
        outPreset: AnimationPreset.fade,
        outDuration: _ticks(0.5),
      ),
    );

    final rule = Clip.drawing(
      id: ids.next('c-'),
      start: _ticks(1.5),
      duration: _ticks(2.7),
      shape: ClipShape.of(ShapeKind.line).copyWith(width: 0.26),
      transform: const ClipTransform(offsetY: 0.03),
      animation: ClipAnimation(
        inPreset: AnimationPreset.fade,
        inDuration: _ticks(0.5),
        outPreset: AnimationPreset.fade,
        outDuration: _ticks(0.5),
      ),
    );

    final strapline = Clip.caption(
      id: ids.next('c-'),
      start: _ticks(1.8),
      duration: _ticks(2.4),
      text: const ClipText(
        text: 'A video editor that gets out of the way.',
        font: 'Inter',
        size: 0.038,
        color: 0xE6FFFFFF,
      ),
      transform: const ClipTransform(offsetY: 0.10),
      animation: ClipAnimation(
        inPreset: AnimationPreset.fade,
        inDuration: _ticks(0.6),
        outPreset: AnimationPreset.fade,
        outDuration: _ticks(0.5),
      ),
    );

    // Over the last shot, and the only line here that is addressed to the
    // person reading it: a sample project exists to be pulled apart, and
    // saying so is cheaper than hoping they try.
    final closing = Clip.caption(
      id: ids.next('c-'),
      start: end - _ticks(4.2),
      duration: _ticks(3.4),
      text: const ClipText(
        text: 'Everything here is yours to take apart.',
        font: 'Playfair Display',
        size: 0.055,
        shadowColor: 0x59000000,
        shadowOffsetY: 0.05,
        shadowBlur: 0.10,
      ),
      animation: ClipAnimation(
        inPreset: AnimationPreset.fade,
        inDuration: _ticks(0.7),
        outPreset: AnimationPreset.fade,
        outDuration: _ticks(0.7),
      ),
    );

    final lanes = [
      for (var i = 0; i < 3; i++)
        Track.of(
          id: ids.next('tr-'),
          kind: TrackKind.text,
          name: 'Text ${i + 1}',
        ),
    ];

    store.run(InsertClips(
      [
        (trackId: lanes[0].id, clip: title, index: null),
        (trackId: lanes[1].id, clip: rule, index: null),
        (trackId: lanes[2].id, clip: strapline, index: null),
        (trackId: lanes[0].id, clip: closing, index: null),
      ],
      label: 'Add titles',
      newTracks: lanes,
    ));
  }

  /// The bed comes up under the opening and goes away under the last fade.
  ///
  /// Equal power rather than linear because that is what a fade between a
  /// sound and silence should be, and because the shape is the thing the
  /// timeline draws — a first launch that shows two straight ramps has shown
  /// the feature at its least interesting.
  static void _fadeTheBed(DocumentStore store) {
    for (final track in store.project.tracks) {
      if (track.kind != TrackKind.audio || track.clips.isEmpty) continue;
      store.run(SetClipAudio(
        track.clips.first.id,
        ClipAudio(
          volume: 0.75,
          fadeIn: _ticks(1.6),
          fadeOut: _ticks(2.4),
          fadeCurve: FadeCurve.equalPower,
        ),
      ));
      return;
    }
  }

  /// The look the middle shot wears, and the faces its captions are set in.
  ///
  /// Both are bundled ones, so both are registered on every installation
  /// whatever the tier says — the sample must not be the one project that
  /// renders differently on a machine without Pro.
  ///
  /// Named here rather than only at their use sites so [contentIsBundled] has
  /// one list to check. A look nobody registered draws ungraded and a face
  /// nobody registered falls back to the system's; both are silent, and both
  /// read as somebody's decision rather than as a missing file, which is
  /// exactly why the sample's own content is asserted instead of trusted.
  static const look = 'Teal & Orange';
  static const fonts = ['Anton', 'Inter', 'Playfair Display'];

  /// True when everything the sample names is in the app's own catalogues.
  static bool contentIsBundled() =>
      BundledLooks.names.contains(look) &&
      fonts.every(BundledFonts.families.contains);

  static Tick _ticks(double seconds) =>
      Tick((seconds * Timebase.project.ticksPerSecond).round());
}
