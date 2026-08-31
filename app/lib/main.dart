import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/workspace.dart';
import 'dev/self_test.dart';
import 'media/fonts.dart';
import 'ui/editor_screen.dart';
import 'ui/new_project_dialog.dart';
import 'ui/start_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(VdodtorApp(workspace: Workspace()));
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
    if (selfTestRequested &&
        widget.workspace.stage == WorkspaceStage.chooser) {
      await openSelfTestProject(widget.workspace);
    }
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
          peakCache: workspace.paths.peaks,
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
