import 'dart:async';

import 'package:flutter/material.dart';

import '../app/crash.dart';
import '../app/workspace.dart';
import '../pro/licensing.dart';
import 'about_dialog.dart';
import 'licence_dialog.dart';
import 'theme.dart';

/// The window before a project is open: make one, or pick up where you left
/// off. No account, no template gallery, no upsell — the product brief's
/// promise starts here.
///
/// The sample project is not a template gallery and the distinction is worth
/// keeping: a gallery is a shop with a shape it wants your film to take, and
/// this is one project, offered once, that exists because an empty editor
/// teaches nobody anything. It sits beside New Project rather than in front of
/// it, so somebody who came here to work is never routed through a demo.
class StartScreen extends StatelessWidget {
  const StartScreen({
    super.key,
    required this.workspace,
    required this.onNewProject,
    required this.onOpenSample,
  });

  final Workspace workspace;
  final VoidCallback onNewProject;

  /// Opens the sample, making it on the first ask — see
  /// [Workspace.openSample].
  final VoidCallback onOpenSample;

  @override
  Widget build(BuildContext context) {
    final projects = workspace.projects;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 48, 32, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('vdodtor',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1,
                    )),
                const SizedBox(height: 6),
                const Text('A video editor that gets out of the way.',
                    style: TextStyle(color: VdColors.dim)),
                const SizedBox(height: 28),
                // Listening to the reporter rather than to the workspace: it
                // is the thing that changes when the offer is dismissed, and
                // it deliberately does not notify from inside a failing frame
                // — see lib/app/crash.dart.
                AnimatedBuilder(
                  animation: workspace.crashes,
                  builder: (context, _) => workspace.crashes.hasUnseen
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _Banner(
                            icon: Icons.bug_report_outlined,
                            tint: VdColors.warn,
                            message: 'vdodtor hit a problem it could not '
                                'handle. A report was written on this machine '
                                'and sent nowhere.',
                            actions: [
                              TextButton(
                                onPressed: workspace.crashes.markSeen,
                                child: const Text('Dismiss'),
                              ),
                              FilledButton(
                                onPressed: () => unawaited(showAboutSheet(
                                  context,
                                  reports: workspace.crashes,
                                  initial: AboutTab.reports,
                                )),
                                child: const Text('Show report'),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                if (workspace.recovery != null) ...[
                  _Banner(
                    icon: Icons.restore,
                    tint: VdColors.warn,
                    message: 'vdodtor closed unexpectedly with '
                        '"${workspace.recovery!.name}" open. Every edit was '
                        'saved as you made it.',
                    actions: [
                      TextButton(
                        onPressed: workspace.dismissRecovery,
                        child: const Text('Dismiss'),
                      ),
                      FilledButton(
                        onPressed: workspace.recoverLastSession,
                        child: const Text('Reopen'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                if (workspace.notice != null) ...[
                  _Banner(
                    icon: Icons.info_outline,
                    tint: VdColors.dim,
                    message: workspace.notice!,
                    actions: [
                      TextButton(
                        onPressed: workspace.dismissNotice,
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                ],
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: onNewProject,
                      icon: const Icon(Icons.add),
                      label: const Text('New project'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 18),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: onOpenSample,
                      icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                      label: const Text('Open the sample'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 18),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    const Text('PROJECTS',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 0.8,
                          fontWeight: FontWeight.w600,
                          color: VdColors.dim,
                        )),
                    const Spacer(),
                    // The folder is a hint, not a heading: it gives way
                    // before the label does.
                    Flexible(
                      child: Text(
                        workspace.paths.library.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                            fontSize: 11, color: VdColors.dim),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: projects.isEmpty
                      ? _EmptyProjects(onOpenSample: onOpenSample)
                      : ListView.separated(
                          itemCount: projects.length,
                          separatorBuilder: (_, _) =>
                              const Divider(height: 1, color: VdColors.line),
                          itemBuilder: (context, i) => _ProjectRow(
                            entry: projects[i],
                            onOpen: () => workspace.openAt(projects[i].path),
                            onForget: () => workspace.forget(projects[i].path),
                          ),
                        ),
                ),
                const Divider(height: 1, color: VdColors.line),
                _Tier(
                  licensing: workspace.licensing,
                  crashes: workspace.crashes,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One line at the bottom of the chooser saying what this installation is,
/// and the only door to the Pro sheet that is not a refusal.
///
/// The sheet has to be reachable when nothing is being blocked: restoring a
/// key on a new machine and taking one off an old one both happen when
/// nobody is trying to export anything, and an offer that only appears at
/// the moment of saying no is an offer somebody has to trigger a refusal to
/// find. It is a status line rather than a banner — the promise at the head
/// of this file is that the chooser has no upsell on it, and a sentence
/// stating what you already have is not one.
class _Tier extends StatelessWidget {
  const _Tier({required this.licensing, required this.crashes});

  final Licensing licensing;

  /// Handed to the About sheet so the problem reports stay reachable after
  /// the banner has been dismissed. One sheet with two doors rather than two
  /// views of one text file.
  final CrashReporter crashes;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: licensing,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  licensing.isPro
                      ? 'vdodtor Pro'
                      : 'Free — the whole editor, up to 1080p, no watermark.',
                  style: const TextStyle(fontSize: 11, color: VdColors.dim),
                ),
              ),
              // The one place in the app that opens the About sheet, and
              // deliberately here rather than in the editor bar: this is the
              // window every launch starts in, which is what "prominent
              // notice" means for the LGPL libraries the sheet lists — and
              // the editor's bar is for editing.
              TextButton(
                onPressed: () =>
                    unawaited(showAboutSheet(context, reports: crashes)),
                child: const Text('About…'),
              ),
              TextButton(
                onPressed: () => unawaited(
                  showLicenceDialog(context, licensing: licensing),
                ),
                child: Text(licensing.isPro ? 'Licence…' : 'vdodtor Pro…'),
              ),
            ],
          ),
        ),
      );
}

/// What the list says before there is a list.
///
/// This is the one screen a first launch is guaranteed to see, so it is where
/// the sample is actually offered — the button above is for the second time
/// somebody wants it. A first-time user with no footage to hand has nothing to
/// do in a new project, and "make a project and drop some footage on it" is
/// advice that assumes they already have some.
class _EmptyProjects extends StatelessWidget {
  const _EmptyProjects({required this.onOpenSample});

  final VoidCallback onOpenSample;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        // Scrolls rather than overflows. This sits under however many banners
        // a bad previous run left behind — a crash report and a recovery offer
        // at once, on a short window — and an empty state that turns into a
        // stripe of overflow warnings would be the app's own error handling
        // reporting a layout bug.
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Nothing here yet. Make a project and drop some footage on it '
              '— or open the sample, a finished edit you can take apart.',
              style: TextStyle(color: VdColors.dim),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: onOpenSample,
              child: const Text('Open the sample project'),
            ),
          ],
        ),
      );
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.entry,
    required this.onOpen,
    required this.onForget,
  });

  final ProjectEntry entry;
  final VoidCallback onOpen;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final missing = !entry.exists;
    return ListTile(
      enabled: !missing,
      onTap: missing ? null : onOpen,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      leading: Icon(
        missing ? Icons.help_outline : Icons.movie_outlined,
        color: missing ? VdColors.dim : VdColors.accent,
      ),
      title: Text(entry.name,
          style: TextStyle(color: missing ? VdColors.dim : VdColors.text)),
      subtitle: Text(
        missing
            ? 'Moved or deleted — ${entry.path}'
            : '${relativeTime(entry.lastOpened)}'
                '${entry.inLibrary ? '' : ' · ${entry.path}'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: VdColors.dim),
      ),
      trailing: missing
          ? IconButton(
              tooltip: 'Remove from this list',
              icon: const Icon(Icons.close, size: 18),
              onPressed: onForget,
            )
          : null,
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.icon,
    required this.tint,
    required this.message,
    required this.actions,
  });

  final IconData icon;
  final Color tint;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        decoration: BoxDecoration(
          color: VdColors.panel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: tint.withValues(alpha: 0.5)),
        ),
        child: Row(
          children: [
            Icon(icon, color: tint, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
            ...actions,
          ],
        ),
      );
}

/// "3 minutes ago". Precise enough to recognise a project by, vague enough not
/// to make the user read a timestamp.
String relativeTime(DateTime when, {DateTime? now}) {
  final delta = (now ?? DateTime.now()).difference(when);
  if (delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes} min ago';
  if (delta.inHours < 24) {
    return '${delta.inHours} hour${delta.inHours == 1 ? '' : 's'} ago';
  }
  if (delta.inDays == 1) return 'yesterday';
  if (delta.inDays < 30) return '${delta.inDays} days ago';
  return '${when.year}-${_two(when.month)}-${_two(when.day)}';
}

String _two(int v) => v.toString().padLeft(2, '0');
