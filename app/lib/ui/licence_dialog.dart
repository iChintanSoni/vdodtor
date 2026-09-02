/// The Pro sheet: what Pro is, how to buy it, where to paste the key, and how
/// to take it off this Mac again.
///
/// One dialog for all four because they are one subject, and because three of
/// them are things somebody does exactly once. It is also the only place in
/// the app where money is mentioned; the export gate points at it rather than
/// growing a second version of this argument.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../pro/checkout.dart';
import '../pro/licence.dart';
import '../pro/licensing.dart';
import 'theme.dart';

/// Shows the sheet. Resolves when it is closed; the tier it may have changed
/// is on the [Licensing] that was handed in, which anything showing a gate is
/// already listening to.
Future<void> showLicenceDialog(
  BuildContext context, {
  required Licensing licensing,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _LicenceDialog(licensing: licensing),
    );

class _LicenceDialog extends StatefulWidget {
  const _LicenceDialog({required this.licensing});

  final Licensing licensing;

  @override
  State<_LicenceDialog> createState() => _LicenceDialogState();
}

class _LicenceDialogState extends State<_LicenceDialog> {
  final TextEditingController _field = TextEditingController();

  /// What the last paste was rejected for. Cleared as soon as the field is
  /// edited again, so the message belongs to the text under it rather than to
  /// whatever was there a minute ago.
  LicenceProblem? _problem;

  bool _working = false;

  /// Set when a link could not be opened. Rare enough that a line under the
  /// button is the whole treatment, and worth having: a button that silently
  /// does nothing is the one failure a user cannot report.
  String? _linkFailure;

  @override
  void initState() {
    super.initState();
    widget.licensing.addListener(_onLicensing);
  }

  void _onLicensing() => setState(() {});

  @override
  void dispose() {
    widget.licensing.removeListener(_onLicensing);
    _field.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    setState(() {
      _working = true;
      _problem = null;
    });
    final check = await widget.licensing.activate(_field.text);
    if (!mounted) return;
    setState(() {
      _working = false;
      _problem = check.problem;
      if (check.isInForce) _field.clear();
    });
  }

  Future<void> _open(Uri url) async {
    final opened = await SystemLinks.open(url);
    if (!mounted || opened) return;
    setState(() => _linkFailure = url.toString());
  }

  Future<void> _paste() async {
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clip?.text;
    if (text == null || !mounted) return;
    setState(() {
      _field.text = text.trim();
      _problem = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final licensing = widget.licensing;

    return AlertDialog(
      backgroundColor: VdColors.panel,
      title: Text(licensing.isPro ? 'vdodtor Pro' : 'Get vdodtor Pro'),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (licensing.isPro) ..._licensed() else ..._offer(),
              if (_linkFailure != null) ...[
                const SizedBox(height: 12),
                SelectableText(
                  'That page would not open. It is at $_linkFailure.',
                  style: const TextStyle(fontSize: 12, color: VdColors.warn),
                ),
              ],
              if (licensing.isDevelopmentBuild) ...[
                const SizedBox(height: 16),
                const _DevelopmentKeyWarning(),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  /// What somebody who has not bought it sees. The free tier is described
  /// first and in full, because it is the product — the paid tier is one line
  /// underneath it, and a sheet that opened with the price would be the
  /// upsell-first behaviour this editor exists in opposition to.
  List<Widget> _offer() {
    final lapsed = widget.licensing.licence;

    return [
      const Text(
        'The editor is free, and complete. Every track, every effect, every '
        'font and every look — at up to 1080p, with no watermark, no account '
        'and no ads, ever.',
        style: TextStyle(fontSize: 13),
      ),
      const SizedBox(height: 10),
      const Text(
        'Pro adds 4K and larger exports, and the premium packs.',
        style: TextStyle(fontSize: 13, color: VdColors.dim),
      ),
      if (lapsed != null) ...[
        const SizedBox(height: 14),
        _Lapsed(lapsed),
      ],
      const SizedBox(height: 18),
      Row(
        children: [
          FilledButton(
            onPressed: () => unawaited(_open(Checkout.buy)),
            child: const Text('Buy vdodtor Pro'),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: () => unawaited(_open(Checkout.findKey)),
            child: const Text('Find my key'),
          ),
        ],
      ),
      const SizedBox(height: 18),
      const _SectionLabel('Already bought it?'),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _field,
              maxLines: 2,
              minLines: 2,
              style: vdMono,
              onChanged: (_) {
                if (_problem != null) setState(() => _problem = null);
              },
              onSubmitted: (_) => unawaited(_activate()),
              decoration: const InputDecoration(
                hintText: 'VDO1.…',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            children: [
              OutlinedButton(
                onPressed: _working ? null : () => unawaited(_paste()),
                child: const Text('Paste'),
              ),
              const SizedBox(height: 6),
              FilledButton(
                onPressed: _working ? null : () => unawaited(_activate()),
                child: const Text('Activate'),
              ),
            ],
          ),
        ],
      ),
      if (_problem != null) ...[
        const SizedBox(height: 10),
        _Problem(_problem!.message),
      ],
      const SizedBox(height: 10),
      const Text(
        'The key is in your receipt. It works on every Mac you use, with no '
        'account and without going online.',
        style: TextStyle(fontSize: 12, color: VdColors.dim),
      ),
    ];
  }

  /// What somebody who has bought it sees: the receipt, and the way off this
  /// machine.
  List<Widget> _licensed() {
    final licence = widget.licensing.licence!;

    return [
      Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 18, color: VdColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              licence.name.isEmpty
                  ? 'Pro is active on this Mac.'
                  : 'Pro is active on this Mac, licensed to ${licence.name}.',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
      const SizedBox(height: 14),
      _Detail('Order', licence.id),
      _Detail(
        licence.isPerpetual ? 'Licence' : 'Renews',
        licence.isPerpetual ? 'Lifetime' : _day(licence.expires!),
      ),
      const SizedBox(height: 18),
      const _SectionLabel('This Mac'),
      const SizedBox(height: 8),
      const Text(
        'Removing the licence here does not use it up. It stays valid, and it '
        'goes straight into the next machine — this is for one you are '
        'selling or handing on.',
        style: TextStyle(fontSize: 12, color: VdColors.dim),
      ),
      const SizedBox(height: 10),
      OutlinedButton(
        onPressed: _working
            ? null
            : () async {
                setState(() => _working = true);
                await widget.licensing.deactivate();
                if (mounted) setState(() => _working = false);
              },
        child: const Text('Remove from this Mac'),
      ),
    ];
  }
}

String _day(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';

const List<String> _months = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// A purchase that has run out. Shown on the offer side, because that is
/// where somebody with a lapsed subscription lands — and "your subscription
/// ended on the 3rd of February" is an answer where "you are on the free
/// tier" is a shrug.
class _Lapsed extends StatelessWidget {
  const _Lapsed(this.licence);

  final Licence licence;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: VdColors.rail,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: VdColors.line),
        ),
        child: Text(
          licence.expires == null
              ? 'The licence on this Mac (order ${licence.id}) is not being '
                  'accepted by this version.'
              : 'The subscription on this Mac (order ${licence.id}) ended on '
                  '${_day(licence.expires!)}. Renewing it sends a new key.',
          style: const TextStyle(fontSize: 12, color: VdColors.warn),
        ),
      );
}

/// Said out loud rather than logged, because a build that trusts a key
/// anybody can sign for is one that gives Pro away — and the moment to find
/// that out is while looking at the licence sheet, not after shipping.
class _DevelopmentKeyWarning extends StatelessWidget {
  const _DevelopmentKeyWarning();

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.construction, size: 16, color: VdColors.warn),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'This build trusts the development signing key, whose private '
              'half is in the source repository. It must not be shipped.',
              style: TextStyle(fontSize: 11, color: VdColors.warn),
            ),
          ),
        ],
      );
}

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            SizedBox(
              width: 70,
              child: Text(label,
                  style: const TextStyle(fontSize: 12, color: VdColors.dim)),
            ),
            SelectableText(value, style: vdMono),
          ],
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
