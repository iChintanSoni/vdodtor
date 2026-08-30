import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/workspace.dart';
import 'package:vdodtor/model/ids.dart';
import 'package:vdodtor/model/project.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/persistence/app_paths.dart';
import 'package:vdodtor/ui/start_screen.dart';

void main() {
  late Directory home;
  late AppPaths paths;

  setUp(() async {
    home = Directory.systemTemp.createTempSync('vdodtor_start_');
    paths = await AppPaths.resolve(home: home.path);
  });
  tearDown(() => home.deleteSync(recursive: true));

  /// Real file I/O does not run under the widget tester's fake async, so all
  /// of it — and anything a tap sets off — has to be handed to [runAsync].
  Future<Workspace> buildWorkspace(List<String> names) async {
    final w = Workspace(
      paths: paths,
      ids: IdGen.seeded(3),
      autosaveDebounce: Duration.zero,
    );
    await w.start();
    for (final name in names) {
      await w.create(
        name: name,
        aspect: ProjectAspect.landscape16x9,
        frameRate: FrameRates.fps30,
      );
    }
    if (names.isNotEmpty) await w.close();
    return w;
  }

  Future<Workspace> workspaceWith(
          WidgetTester tester, List<String> names) async =>
      (await tester.runAsync(() => buildWorkspace(names)))!;

  /// Lets whatever a tap started actually reach the disk, then repaints.
  ///
  /// A file read completes on the real event loop but resumes on the tester's
  /// fake one, so a chain of them needs the two alternated: real time to let
  /// the read finish, a pump to let the continuation run and start the next.
  Future<void> settleIo(WidgetTester tester, {int rounds = 16}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  }

  Future<void> pumpStart(WidgetTester tester, Workspace workspace,
      {VoidCallback? onNew}) async {
    await tester.pumpWidget(MaterialApp(
      home: AnimatedBuilder(
        animation: workspace,
        builder: (_, _) => StartScreen(
          workspace: workspace,
          onNewProject: onNew ?? () {},
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('an empty library says so rather than showing a bare list',
      (tester) async {
    await pumpStart(tester, await workspaceWith(tester, []));

    expect(find.text('New project'), findsOneWidget);
    expect(find.textContaining('Nothing here yet'), findsOneWidget);
  });

  testWidgets('lists projects and opens the one that is tapped',
      (tester) async {
    final workspace = await workspaceWith(tester, ['First', 'Second']);
    await pumpStart(tester, workspace);

    expect(find.text('Second'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);

    await tester.tap(find.text('First'));
    await settleIo(tester);

    expect(workspace.stage, WorkspaceStage.editing);
    expect(workspace.open!.name, 'First');
  });

  testWidgets('a project that has gone away is shown, not hidden',
      (tester) async {
    final workspace = await workspaceWith(tester, ['Gone']);
    File(workspace.projects.single.path).deleteSync();
    await tester.runAsync(workspace.refresh);
    await pumpStart(tester, workspace);

    expect(find.text('Gone'), findsOneWidget);
    expect(find.textContaining('Moved or deleted'), findsOneWidget);

    // Tapping a missing project does nothing; removing it from the list does.
    await tester.tap(find.text('Gone'));
    await settleIo(tester);
    expect(workspace.stage, WorkspaceStage.chooser);

    await tester.tap(find.byIcon(Icons.close));
    await settleIo(tester);
    expect(workspace.projects, isEmpty);
  });

  testWidgets('offers back the project the app died with', (tester) async {
    final workspace = await tester.runAsync(() async {
      final killed = await buildWorkspace(['Holiday']);
      await killed.openAt(killed.projects.single.path);
      killed.dispose(); // no flush, no session close

      final next = Workspace(paths: paths, autosaveDebounce: Duration.zero);
      await next.start();
      return next;
    });
    await pumpStart(tester, workspace!);

    expect(find.textContaining('closed unexpectedly'), findsOneWidget);
    await tester.tap(find.text('Reopen'));
    await settleIo(tester);

    expect(workspace.stage, WorkspaceStage.editing);
    expect(workspace.open!.name, 'Holiday');
  });

  testWidgets('a dismissed crash notice does not come back', (tester) async {
    final workspace = await tester.runAsync(() async {
      final killed = await buildWorkspace(['Holiday']);
      await killed.openAt(killed.projects.single.path);
      killed.dispose();

      final next = Workspace(paths: paths, autosaveDebounce: Duration.zero);
      await next.start();
      return next;
    });
    await pumpStart(tester, workspace!);
    expect(find.textContaining('closed unexpectedly'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await settleIo(tester);
    expect(find.textContaining('closed unexpectedly'), findsNothing);

    final relaunched = await tester.runAsync(() async {
      final next = Workspace(paths: paths, autosaveDebounce: Duration.zero);
      await next.start();
      return next;
    });
    expect(relaunched!.recovery, isNull);
  });

  group('relativeTime', () {
    final now = DateTime(2026, 8, 30, 12);

    test('reads like a person would say it', () {
      expect(relativeTime(now.subtract(const Duration(seconds: 20)), now: now),
          'just now');
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now),
          '5 min ago');
      expect(relativeTime(now.subtract(const Duration(hours: 1)), now: now),
          '1 hour ago');
      expect(relativeTime(now.subtract(const Duration(hours: 5)), now: now),
          '5 hours ago');
      expect(relativeTime(now.subtract(const Duration(days: 1)), now: now),
          'yesterday');
      expect(relativeTime(now.subtract(const Duration(days: 9)), now: now),
          '9 days ago');
      expect(relativeTime(DateTime(2025, 1, 5), now: now), '2025-01-05');
    });
  });
}
