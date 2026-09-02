/// The export sheet: four choices, then a bar that moves.
///
/// One dialog for both halves rather than a setup sheet followed by a progress
/// window, because they are one thing the user is doing and the second window
/// would arrive exactly when they have stopped looking. The dialog is not
/// dismissible while an export is running — the only way out is Cancel, which
/// stops it and takes the half-written file with it, or waiting for it to
/// finish. A dialog that could be dismissed while writing would leave an
/// export nothing on screen was attached to.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../engine/export_plan.dart';
import '../model/project.dart';
import '../pro/entitlement.dart';
import 'theme.dart';

/// Shows the sheet. Returns the path written, or null if nothing was.
Future<String?> showExportDialog(
  BuildContext context, {
  required Project project,
  required String projectName,
  required Entitlement entitlement,
}) =>
    showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExportDialog(
        project: project,
        projectName: projectName,
        entitlement: entitlement,
      ),
    );

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({
    required this.project,
    required this.projectName,
    required this.entitlement,
  });

  final Project project;
  final String projectName;
  final Entitlement entitlement;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  late ExportPlan _plan =
      ExportPlan.of(widget.project, tier: widget.entitlement.tier);
  Exporter? _exporter;
  String? _path;
  String? _problem;
  bool _picking = false;

  bool get _running => _exporter?.progress.isRunning ?? false;

  @override
  void initState() {
    super.initState();
    // Buying Pro is something that happens *while this sheet is open* — it is
    // the sheet that told them they needed it — so the gate has to lift under
    // them rather than waiting to be closed and reopened.
    widget.entitlement.addListener(_onTier);
  }

  void _onTier() {
    if (!mounted) return;
    setState(() => _plan = _plan.copyWith(tier: widget.entitlement.tier));
  }

  @override
  void dispose() {
    widget.entitlement.removeListener(_onTier);
    // Cancels it if it is still going, which is the right answer: the dialog
    // is the only thing that was watching.
    _exporter?.removeListener(_onProgress);
    _exporter?.dispose();
    super.dispose();
  }

  void _onProgress() {
    if (!mounted) return;
    final exporter = _exporter;
    if (exporter == null) return;
    if (exporter.progress.isRunning) {
      setState(() {});
      return;
    }

    // However it ended, it has ended: let go of the handle rather than leaving
    // it for a second attempt to overwrite, which would leak the first
    // export's thread and its half-written file with it.
    final state = exporter.progress.state;
    final failure =
        state == ExportState.failed ? exporter.failureMessage : null;
    exporter.removeListener(_onProgress);
    exporter.dispose();
    setState(() {
      _exporter = null;
      _problem = failure;
    });
    // Cancelling leaves the sheet up with its settings, because somebody who
    // stopped an export usually meant to change something about it.
    if (state == ExportState.done) Navigator.of(context).pop(_path);
  }

  /// Where to write, and the check that there is room for it.
  ///
  /// The panel comes first and the disk check second, deliberately: the free
  /// space that matters is on the volume the user picked, and asking before
  /// they have picked one would be a question about the wrong disk.
  Future<void> _start() async {
    if (_picking || _running) return;
    // The button is already disabled; this is the check that matters, because
    // it is the one on the path to a file rather than on the path to a pixel.
    if (!_plan.isPermitted) return;
    setState(() {
      _picking = true;
      _problem = null;
    });
    try {
      final file = await MediaAccess.saveFile(
        name: '${widget.projectName}.mp4',
        extension: 'mp4',
        message: 'Where should the export go?',
        prompt: 'Export',
      );
      if (file == null || !mounted) return;

      if (_plan.hasRoomFor(file.path) == false) {
        setState(() => _problem =
            'There is not enough room on that disk for about '
            '${formatBytes(_plan.estimatedBytes)}.');
        return;
      }

      final exporter = Exporter.start(
        _plan.timelineFor(widget.project),
        file.path,
        settings: _plan.settings,
      );
      exporter.addListener(_onProgress);
      setState(() {
        _path = file.path;
        _exporter = exporter;
      });
    } on EngineException catch (error) {
      if (mounted) setState(() => _problem = error.message);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _cancel() {
    final exporter = _exporter;
    if (exporter == null) {
      Navigator.of(context).pop();
      return;
    }
    exporter.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: VdColors.panel,
      title: const Text('Export'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      // Scrollable because the sheet grows: a gate panel, a disk warning and
      // an encoder failure can all be on it at once, and a short window is
      // not a reason to hide the button that gets out of it.
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_exporter == null) ..._settings() else _bar(),
              if (_problem != null) ...[
                const SizedBox(height: 16),
                _Problem(_problem!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cancel,
          child: Text(_running ? 'Stop' : 'Cancel'),
        ),
        FilledButton(
          onPressed: _running || _picking || _plan.frameCount == 0 ||
                  !_plan.isPermitted
              ? null
              : () => unawaited(_start()),
          child: const Text('Export…'),
        ),
      ],
    );
  }

  List<Widget> _settings() {
    final output = _plan.outputFormat;
    final bytes = _plan.estimatedBytes;

    return [
      const _SectionLabel('Size'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (final resolution in ExportResolution.values)
            ChoiceChip(
              // A locked size is still selectable, deliberately. Picking it
              // shows exactly what it would produce — the dimensions, the
              // bitrate, the size on disk — and the refusal is on the button
              // underneath. A chip that could not be pressed would make the
              // user guess what they were being sold.
              label: _plan.needsPro(resolution)
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(resolution.label),
                      const SizedBox(width: 6),
                      const _ProBadge(),
                    ])
                  : Text(resolution.label),
              selected: resolution == _plan.resolution,
              onSelected: (_) =>
                  setState(() => _plan = _plan.copyWith(resolution: resolution)),
            ),
        ],
      ),
      const SizedBox(height: 20),
      const _SectionLabel('Format'),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: [
          for (final codec in ExportCodec.values)
            ChoiceChip(
              label: Text(codec.label),
              selected: codec == _plan.codec,
              onSelected: (_) => setState(() => _plan = _plan.copyWith(codec: codec)),
            ),
        ],
      ),
      const SizedBox(height: 4),
      CheckboxListTile(
        value: _plan.includeAudio,
        onChanged: (on) =>
            setState(() => _plan = _plan.copyWith(includeAudio: on ?? true)),
        title: const Text('Include sound', style: TextStyle(fontSize: 13)),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: EdgeInsets.zero,
        dense: true,
      ),
      const SizedBox(height: 12),
      // Everything the choices above add up to, in one line. A picker that
      // does not say what it will produce makes people export twice to find
      // out.
      Text(
        '${output.width} × ${output.height} · '
        '${formatBitrate(_plan.videoBitrate)} · '
        '${_plan.frameCount} frames · about ${formatBytes(bytes)}',
        style: vdMono.copyWith(color: VdColors.dim),
      ),
      if (_plan.frameCount == 0) ...[
        const SizedBox(height: 12),
        const Text('There is nothing on the timeline to export yet.',
            style: TextStyle(fontSize: 12, color: VdColors.dim)),
      ],
      if (!_plan.isPermitted) ...[
        const SizedBox(height: 14),
        _ProGate(output),
      ],
    ];
  }

  Widget _bar() {
    final progress = _exporter!.progress;
    final remaining = progress.secondsRemaining;
    final name = _path == null ? '' : _path!.split(Platform.pathSeparator).last;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(name, style: const TextStyle(fontSize: 13)),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: progress.fraction,
            minHeight: 6,
            backgroundColor: VdColors.rail,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          '${progress.framesWritten} of ${progress.framesTotal} frames'
          '${remaining == null ? '' : ' · about '
              '${formatRoughDuration(remaining)} left'}',
          style: vdMono.copyWith(color: VdColors.dim),
        ),
      ],
    );
  }
}

/// The one place in the app that says no.
///
/// It says what is locked, what it costs and — the sentence that matters most
/// in a product positioned against Filmora and CapCut — what is *not* locked.
/// The free tier is the whole editor: every track, every effect, every font
/// and no watermark on anything, ever. A gate that let people believe
/// otherwise would cost more than the export it withheld.
class _ProGate extends StatelessWidget {
  const _ProGate(this.output);

  final ProjectFormat output;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: VdColors.rail,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: VdColors.line),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _ProBadge(),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Exporting at ${output.width} × ${output.height} is part '
                    'of vdodtor Pro.',
                    style: const TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Up to 1080p stays free: every track, every effect, and '
                    'no watermark on anything, ever.',
                    style: TextStyle(fontSize: 12, color: VdColors.dim),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// The badge on a locked chip and on the gate. Small, and not red: this is a
/// price, not an error.
class _ProBadge extends StatelessWidget {
  const _ProBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: VdColors.accent.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: VdColors.accent.withValues(alpha: 0.5)),
        ),
        child: const Text(
          'PRO',
          style: TextStyle(
            fontSize: 9,
            letterSpacing: 0.6,
            fontWeight: FontWeight.w700,
            color: VdColors.accent,
          ),
        ),
      );
}

class _Problem extends StatelessWidget {
  const _Problem(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: VdColors.warn),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: const TextStyle(fontSize: 12, color: VdColors.warn)),
          ),
        ],
      );
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
