import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/workspace.dart';
import 'package:vdodtor/commands/edits.dart';
import 'package:vdodtor/engine/media_probe.dart';
import 'package:vdodtor/media/sample_project.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/track.dart';
import 'package:vdodtor/persistence/app_paths.dart';
import 'package:vdodtor/persistence/first_run.dart';
import 'package:vdodtor/persistence/project_file.dart';

import '../media/fakes.dart';

/// The chooser's half of the first-run experience: the sample opens, opens
/// again as itself rather than as a copy, and the tour is offered once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;
  late AppPaths paths;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('vdodtor_first_');
    paths = await AppPaths.resolve(home: home.path);
  });
  tearDown(() => home.deleteSync(recursive: true));

  /// A workspace whose probe answers from a table, so the sample can be built
  /// with no engine — which is also what makes this run on CI.
  Future<Workspace> started() async {
    final w = Workspace(
      paths: paths,
      ids: IdGen.seeded(11),
      access: FakeFileAccess(),
      prober: _SampleProber(),
      autosaveDebounce: Duration.zero,
    );
    await w.start();
    return w;
  }

  group('the sample project', () {
    test('is made on the first ask and opened', () async {
      final w = await started();
      await w.openSample();

      expect(w.stage, WorkspaceStage.editing);
      expect(w.open!.name, SampleProject.name);
      expect(w.open!.project.mainTrack.clips, hasLength(3));
      expect(File(w.open!.path).existsSync(), isTrue);
      expect(w.notice, isNull);
      w.dispose();
    });

    test('the second ask reopens theirs rather than making a second', () async {
      final w = await started();
      await w.openSample();
      final path = w.open!.path;

      // Somebody re-cuts it, then comes back to the chooser. What they want
      // next time is their version — a button that quietly made "Sample
      // project 2" would have shelved their work without deleting it.
      w.open!.store.run(DeleteClips({w.open!.project.mainTrack.clips.last.id}));
      await w.close();

      await w.openSample();
      expect(w.open!.path, path);
      expect(w.open!.project.mainTrack.clips, hasLength(2));
      expect(
        paths.library
            .listSync()
            .where((e) => e.path.endsWith('.$kProjectExtension'))
            .length,
        1,
      );
      w.dispose();
    });

    test('the footage lands in the library, not in the app bundle', () async {
      final w = await started();
      await w.openSample();

      final staged =
          Directory('${paths.library.path}/${SampleProject.mediaFolderName}');
      expect(staged.existsSync(), isTrue);
      for (final asset in w.open!.project.media.values) {
        expect(asset.path, startsWith(staged.path));
        expect(File(asset.path).existsSync(), isTrue);
      }
      w.dispose();
    });

    test('reopens with its media after a quit', () async {
      final first = await started();
      await first.openSample();
      final path = first.open!.path;
      await first.shutdown();
      first.dispose();

      final second = await started();
      await second.openAt(path);

      expect(second.stage, WorkspaceStage.editing);
      expect(second.open!.unreachableMediaIds, isEmpty);
      expect(second.open!.project.tracks.where((t) => t.kind == TrackKind.text),
          hasLength(3));
      second.dispose();
    });
  });

  group('the tour marker', () {
    test('is pending until it is written, and then never again', () async {
      final firstRun = FirstRun(paths.tourSeenFile);
      expect(firstRun.tourPending, isTrue);

      await firstRun.markTourSeen();
      expect(firstRun.tourPending, isFalse);

      // A second machine — a second container — has never seen it.
      final elsewhere = Directory.systemTemp.createTempSync('vdodtor_other_');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      final other = await AppPaths.resolve(home: elsewhere.path);
      expect(FirstRun(other.tourSeenFile).tourPending, isTrue);
    });

    test('a marker that cannot be written is not a failure', () async {
      // A file where the folder should be, so creating the parent throws.
      // Being unable to record the marker means the tour is offered again,
      // which is a mild annoyance and not a reason to fail a launch.
      final blocked = File('${paths.support.path}/blocked')
        ..writeAsStringSync('');
      final nowhere = FirstRun(File('${blocked.path}/tour-seen'));

      await expectLater(nowhere.markTourSeen(), completes);
      expect(nowhere.tourPending, isTrue);
    });

    test('the workspace reads it from its own storage', () async {
      final w = await started();
      expect(w.firstRun.tourPending, isTrue);
      await w.firstRun.markTourSeen();
      expect(w.firstRun.tourPending, isFalse);
      w.dispose();
    });
  });
}

/// Answers for whatever [SampleProject.stage] happened to write, keyed on the
/// extension rather than on a path, because the path is a temporary directory
/// this test does not choose.
class _SampleProber extends FakeProber {
  _SampleProber() : super(const {});

  @override
  Future<List<ProbeOutcome>> probeAll(List<String> paths) async => [
        for (final path in paths)
          (
            path: path,
            probe: path.endsWith('.m4a')
                ? audioProbe(seconds: 15)
                : videoProbe(seconds: 5, audio: false),
            error: null,
          ),
      ];
}
