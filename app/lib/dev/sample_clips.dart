import 'dart:io';

import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../commands/document_store.dart';
import '../commands/edits.dart';
import '../engine/media_probe.dart';
import '../model/clip.dart';
import '../model/ids.dart';
import '../model/time.dart';

/// The clips bundled with debug builds.
///
/// The App Sandbox lets the app read its own bundle and nothing else, so until
/// import lands these are the only files vdodtor can legitimately open — and
/// something has to be on the timeline for the preview pipeline to be worth
/// looking at. This file goes when the file picker arrives.
List<File> sampleMediaFiles() {
  final exe = File(Platform.resolvedExecutable).parent; // …/Contents/MacOS
  final bundled = Directory('${exe.parent.path}/Frameworks/App.framework/'
      'Resources/flutter_assets/assets/dev');
  final dir = bundled.existsSync()
      ? bundled
      : Directory('${Directory.current.path}/assets/dev');
  if (!dir.existsSync()) return const [];

  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.mp4'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Appends every bundled sample to the main track, as ordinary edits: they go
/// through the command log, so they undo and they autosave like anything else.
/// Returns how many landed.
int addSampleClips(DocumentStore store, {IdGen? ids}) {
  final gen = ids ?? IdGen();
  const probeService = MediaProbeService();
  final trackId = store.project.mainTrack.id;

  var added = 0;
  store.endGesture();
  for (final file in sampleMediaFiles()) {
    final name = file.uri.pathSegments.last;
    try {
      final asset = probeService.probe(
        id: gen.next('m-'),
        path: file.path,
        displayName: name,
      );
      if (!asset.probe.hasVideo) continue;

      store.run(AddMedia(asset));
      store.run(InsertClip(
        trackId,
        Clip(
          id: gen.next('c-'),
          mediaId: asset.id,
          // A magnetic track appends; the start is a formality.
          start: Tick.zero,
          duration: asset.probe.duration,
          label: name,
        ),
      ));
      added++;
    } on EngineException {
      // A sample that will not probe is not worth failing over.
      continue;
    }
  }
  store.endGesture();
  return added;
}
