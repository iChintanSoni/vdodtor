import 'package:flutter/material.dart';

import '../app/workspace.dart';
import 'theme.dart';

/// The window before a project is open: make one, or pick up where you left
/// off. No account, no template gallery, no upsell — the product brief's
/// promise starts here.
class StartScreen extends StatelessWidget {
  const StartScreen({
    super.key,
    required this.workspace,
    required this.onNewProject,
  });

  final Workspace workspace;
  final VoidCallback onNewProject;

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
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: onNewProject,
                    icon: const Icon(Icons.add),
                    label: const Text('New project'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 18),
                    ),
                  ),
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
                      ? const _EmptyProjects()
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyProjects extends StatelessWidget {
  const _EmptyProjects();

  @override
  Widget build(BuildContext context) => const Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            'Nothing here yet. Make a project and drop some footage on it.',
            style: TextStyle(color: VdColors.dim),
          ),
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
