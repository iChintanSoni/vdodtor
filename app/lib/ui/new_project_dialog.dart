import 'package:flutter/material.dart';

import '../model/project.dart';
import '../model/time.dart';
import 'theme.dart';

/// What the New Project dialog collects. Aspect and frame rate are fixed at
/// creation because every layout decision downstream depends on them (product
/// brief §4).
final class NewProjectRequest {
  const NewProjectRequest({
    required this.name,
    required this.aspect,
    required this.frameRate,
  });

  final String name;
  final ProjectAspect aspect;
  final Rational frameRate;

  ProjectFormat get format =>
      ProjectFormat.fromAspect(aspect, frameRate: frameRate);
}

Future<NewProjectRequest?> showNewProjectDialog(
  BuildContext context, {
  String suggestedName = 'Untitled',
}) =>
    showDialog<NewProjectRequest>(
      context: context,
      builder: (_) => _NewProjectDialog(suggestedName: suggestedName),
    );

class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog({required this.suggestedName});

  final String suggestedName;

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  late final TextEditingController _name =
      TextEditingController(text: widget.suggestedName);

  ProjectAspect _aspect = ProjectAspect.landscape16x9;
  Rational _frameRate = FrameRates.fps30;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(NewProjectRequest(
        name: _name.text,
        aspect: _aspect,
        frameRate: _frameRate,
      ));

  @override
  Widget build(BuildContext context) {
    final format = ProjectFormat.fromAspect(_aspect, frameRate: _frameRate);

    return AlertDialog(
      backgroundColor: VdColors.panel,
      title: const Text('New project'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 24),
            const _SectionLabel('Aspect ratio'),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final aspect in ProjectAspect.values)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _AspectTile(
                        aspect: aspect,
                        selected: aspect == _aspect,
                        onTap: () => setState(() => _aspect = aspect),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            const _SectionLabel('Frame rate'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final rate in FrameRates.offered)
                  ChoiceChip(
                    label: Text('${rate.numerator ~/ rate.denominator} fps'),
                    selected: rate == _frameRate,
                    onSelected: (_) => setState(() => _frameRate = rate),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              '${format.width} × ${format.height}',
              style: vdMono.copyWith(color: VdColors.dim),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
          color: VdColors.dim,
        ),
      );
}

/// An aspect shown as its own shape. Four numbers in a row all look alike;
/// four rectangles do not.
class _AspectTile extends StatelessWidget {
  const _AspectTile({
    required this.aspect,
    required this.selected,
    required this.onTap,
  });

  final ProjectAspect aspect;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        label: aspect.label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            height: 96,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? VdColors.accent : VdColors.line,
                width: selected ? 2 : 1,
              ),
              color: selected
                  ? VdColors.accent.withValues(alpha: 0.10)
                  : Colors.transparent,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 42,
                  child: AspectRatio(
                    aspectRatio: aspect.wide / aspect.tall,
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected ? VdColors.accent : VdColors.dim,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(aspect.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? VdColors.text : VdColors.dim,
                    )),
              ],
            ),
          ),
        ),
      );
}
