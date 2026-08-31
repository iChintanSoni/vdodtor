import 'package:flutter/material.dart';

import 'shortcuts.dart';
import 'theme.dart';

/// The shortcut list, generated from the table that binds them.
///
/// Generated rather than written out, which is the whole point: a hand-kept
/// list is wrong the first time somebody changes a key and nobody finds out,
/// because the only thing that reads it is a person who already believed it.
class ShortcutSheet extends StatelessWidget {
  const ShortcutSheet({super.key});

  /// Opens the sheet, or closes it if it is already open.
  ///
  /// Toggling matters because the shortcut that opens it — ⌘/ — is still live
  /// underneath, so without this the second press would push a second copy on
  /// top of the first.
  static void toggle(BuildContext context) {
    if (_isOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      return;
    }
    _isOpen = true;
    showDialog<void>(
      context: context,
      builder: (_) => const ShortcutSheet(),
    ).whenComplete(() => _isOpen = false);
  }

  static bool _isOpen = false;

  @override
  Widget build(BuildContext context) {
    final groups = <ShortcutGroup, List<ShortcutSpec>>{};
    for (final spec in editorShortcuts) {
      groups.putIfAbsent(spec.group, () => []).add(spec);
    }

    return Dialog(
      backgroundColor: VdColors.panel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Keyboard shortcuts',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: VdColors.line),
            Flexible(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // Iterated over the enum rather than over the map, so the
                  // sheet reads in the order the groups were declared instead
                  // of the order the table happens to mention them.
                  for (final group in ShortcutGroup.values)
                    if (groups[group] case final specs?) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
                        child: Text(group.title,
                            style: const TextStyle(
                                color: VdColors.dim,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.6)),
                      ),
                      for (final spec in specs) _Row(spec: spec),
                    ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.spec});

  final ShortcutSpec spec;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        child: Row(
          children: [
            Expanded(child: Text(spec.label)),
            // The first synonym only. ⌘= and ⌘+ are one intention typed on
            // two keyboards, and printing both would make the list look like
            // it has twice as much in it to remember.
            _Chord(text: describeChord(spec.keys.first)),
          ],
        ),
      );
}

class _Chord extends StatelessWidget {
  const _Chord({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: VdColors.rail,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: VdColors.line),
        ),
        child: Text(text, style: vdMono.copyWith(color: VdColors.text)),
      );
}
