import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/crash.dart';
import 'app/workspace.dart';
import 'dev/self_test.dart';
import 'media/fonts.dart';
import 'media/looks.dart';
import 'media/packs.dart';
import 'ui/editor_screen.dart';
import 'ui/new_project_dialog.dart';
import 'ui/start_screen.dart';
import 'ui/theme.dart';

void main() {
  // Before anything else, including the bindings: a fault while Flutter is
  // starting up is exactly the one nobody can reproduce, and the handlers cost
  // two assignments. Nothing is sent anywhere — see lib/app/crash.dart.
  final crashes = CrashReporter()..install();

  WidgetsFlutterBinding.ensureInitialized();
  runApp(VdodtorApp(workspace: Workspace(crashes: crashes)));
}

/// The window. It shows exactly one of two things — the project chooser or an
/// open project — and owns the quit path, which is the only moment the app has
/// to be sure the document reached the disk.
class VdodtorApp extends StatefulWidget {
  const VdodtorApp({super.key, required this.workspace});

  final Workspace workspace;

  @override
  State<VdodtorApp> createState() => _VdodtorAppState();
}

class _VdodtorAppState extends State<VdodtorApp> {
  late final AppLifecycleListener _lifecycle;

  /// Whether this machine has yet to be shown the sixty-second tour.
  ///
  /// Read once at launch and kept here rather than asked again per project:
  /// the editor is rebuilt whenever a different project is opened, and a
  /// question answered off the disk each time would run the tour again for
  /// anybody who closed a project before finishing it.
  bool _tourPending = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    unawaited(_launch());
  }

  Future<void> _launch() async {
    // Before anything can open a project, because a caption drawn before its
    // face is registered falls back to the system's and nothing would redraw
    // it afterwards.
    await BundledFonts.load();
    await widget.workspace.start();

    // After storage is resolved, because the user's own looks live under it —
    // and before any project opens, because a clip naming a look that is not
    // registered yet renders ungraded and registering it afterwards would not
    // redraw the frame. `start` leaves the chooser up, so there is no project
    // in between.
    if (widget.workspace.stage != WorkspaceStage.failed) {
      await BundledLooks.load(
          library: BundledLooks.libraryOf(widget.workspace.paths.support));

      // After the built-in looks and before any project, for the same reason:
      // a clip naming a look that is not registered yet renders ungraded and
      // registering it afterwards would not redraw the frame. Every pack is
      // registered whatever the tier says — a locked look still has to draw
      // for anybody whose project already names it. See lib/media/packs.dart.
      await ContentPacks.load(
          installed:
              ContentPacks.libraryOf(widget.workspace.paths.support));
    }

    if (widget.workspace.stage != WorkspaceStage.failed && mounted) {
      setState(() => _tourPending = widget.workspace.firstRun.tourPending);
    }

    if (widget.workspace.stage == WorkspaceStage.chooser) {
      if (sampleSelfTestRequested) {
        await widget.workspace.openSample();
      } else if (selfTestRequested) {
        await openSelfTestProject(widget.workspace);
      }
    }
  }

  /// The tour has been finished or skipped; there is no difference. Written
  /// down here rather than in the editor, because it is a fact about the
  /// installation — see `lib/persistence/first_run.dart`.
  void _finishTour() {
    setState(() => _tourPending = false);
    unawaited(widget.workspace.firstRun.markTourSeen());
  }

  /// ⌘Q and the red button both land here. Autosave has already written every
  /// committed edit; this flushes whatever the debounce is still holding and
  /// clears the session marker, so the next launch knows the app was quit
  /// rather than killed.
  Future<AppExitResponse> _onExitRequested() async {
    await widget.workspace.shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.workspace.dispose();
    super.dispose();
  }

  Future<void> _newProject(BuildContext context) async {
    final request = await showNewProjectDialog(context);
    if (request == null) return;
    await widget.workspace.create(
      name: request.name,
      aspect: request.aspect,
      frameRate: request.frameRate,
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'vdodtor',
        debugShowCheckedModeBanner: false,
        theme: vdodtorTheme(),
        home: AnimatedBuilder(
          animation: widget.workspace,
          builder: (context, _) => _stage(context),
        ),
      );

  Widget _stage(BuildContext context) {
    final workspace = widget.workspace;
    switch (workspace.stage) {
      case WorkspaceStage.starting:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );

      case WorkspaceStage.failed:
        return _StorageFailure(error: workspace.failure);

      case WorkspaceStage.chooser:
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
                unawaited(_newProject(context)),
          },
          child: Focus(
            autofocus: true,
            child: StartScreen(
              workspace: workspace,
              onNewProject: () => unawaited(_newProject(context)),
              onOpenSample: () => unawaited(workspace.openSample()),
            ),
          ),
        );

      case WorkspaceStage.editing:
        final open = workspace.open!;
        return EditorScreen(
          // A different project is a different engine, a different document
          // and a different playhead: rebuild the state rather than migrate it.
          key: ValueKey(open.path),
          open: open,
          access: workspace.fileAccess,
          licensing: workspace.licensing,
          peakCache: workspace.paths.peaks,
          lookLibrary: BundledLooks.libraryOf(workspace.paths.support),
          // Whatever project this is. The chooser steers a first launch at the
          // sample, so that is what it will usually be pointing at — but
          // somebody whose first act was New Project is the person who needs
          // the tour most, and a rule that only toured the sample would leave
          // them with no tour at all.
          showTour: _tourPending,
          onTourFinished: _finishTour,
          onClose: () => unawaited(workspace.close()),
        );
    }
  }
}

class _StorageFailure extends StatelessWidget {
  const _StorageFailure({required this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SelectableText(
              'vdodtor could not reach its own storage, so it cannot open or '
              'create projects.\n\n$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: VdColors.dim),
            ),
          ),
        ),
      );
}
