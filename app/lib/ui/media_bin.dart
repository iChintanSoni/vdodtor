import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../media/thumbnails.dart';
import '../model/media.dart';
import '../model/time.dart';
import 'theme.dart';

/// Everything the project has imported.
///
/// The bin is the answer to "where did my footage go" — a clip deleted from
/// the timeline is still here, and an asset that lost its file is still here
/// too, greyed out, rather than quietly gone.
class MediaBin extends StatelessWidget {
  const MediaBin({
    super.key,
    required this.assets,
    required this.thumbnails,
    required this.unreachable,
    required this.onImport,
    required this.onPlace,
    required this.onRemove,
    this.busy = false,
  });

  final List<MediaAsset> assets;
  final ThumbnailCache thumbnails;

  /// Ids whose file the app cannot currently reach.
  final Set<String> unreachable;

  final VoidCallback onImport;
  final void Function(MediaAsset) onPlace;
  final void Function(MediaAsset) onRemove;

  /// True while an import is probing. The bin says so rather than appearing
  /// to have ignored the drop.
  final bool busy;

  @override
  Widget build(BuildContext context) => Container(
        width: 232,
        color: VdColors.rail,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BinHeader(count: assets.length, busy: busy, onImport: onImport),
            const Divider(height: 1, color: VdColors.line),
            Expanded(
              child: assets.isEmpty
                  ? const _EmptyBin()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: assets.length,
                      itemBuilder: (context, i) => _AssetRow(
                        asset: assets[i],
                        thumbnails: thumbnails,
                        missing: unreachable.contains(assets[i].id),
                        onPlace: () => onPlace(assets[i]),
                        onRemove: () => onRemove(assets[i]),
                      ),
                    ),
            ),
          ],
        ),
      );
}

class _BinHeader extends StatelessWidget {
  const _BinHeader({
    required this.count,
    required this.busy,
    required this.onImport,
  });

  final int count;
  final bool busy;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: [
            const Text('MEDIA',
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                  color: VdColors.dim,
                )),
            const SizedBox(width: 8),
            if (busy)
              const SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              )
            else if (count > 0)
              Text('$count',
                  style: const TextStyle(fontSize: 11, color: VdColors.dim)),
            const Spacer(),
            IconButton(
              tooltip: 'Import media (⌘I)',
              icon: const Icon(Icons.add, size: 18),
              visualDensity: VisualDensity.compact,
              onPressed: onImport,
            ),
          ],
        ),
      );
}

class _EmptyBin extends StatelessWidget {
  const _EmptyBin();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.fromLTRB(16, 24, 16, 16),
        child: Column(
          children: [
            Icon(Icons.download_outlined, color: VdColors.dim, size: 22),
            SizedBox(height: 10),
            Text(
              'Drop footage anywhere in this window, or press ⌘I.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: VdColors.dim, height: 1.4),
            ),
          ],
        ),
      );
}

class _AssetRow extends StatefulWidget {
  const _AssetRow({
    required this.asset,
    required this.thumbnails,
    required this.missing,
    required this.onPlace,
    required this.onRemove,
  });

  final MediaAsset asset;
  final ThumbnailCache thumbnails;
  final bool missing;
  final VoidCallback onPlace;
  final VoidCallback onRemove;

  @override
  State<_AssetRow> createState() => _AssetRowState();
}

class _AssetRowState extends State<_AssetRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    final probe = asset.probe;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.missing
            ? 'Missing: ${asset.path}'
            : '${asset.path}\nDouble-click to add to the timeline',
        waitDuration: const Duration(milliseconds: 700),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          color: _hovered ? VdColors.panel : Colors.transparent,
          child: Row(
            children: [
              // The remove button sits outside this, deliberately: a double-tap
              // recognizer wrapping it would make every click on the × wait
              // 300 ms to find out it was not the first half of a double one.
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: widget.missing ? null : widget.onPlace,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 64,
                        height: 40,
                        child: _Thumbnail(
                          asset: asset,
                          thumbnails: widget.thumbnails,
                          missing: widget.missing,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              asset.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: widget.missing
                                    ? VdColors.dim
                                    : VdColors.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.missing
                                  ? 'File not found'
                                  : _subtitle(probe),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: widget.missing
                                    ? VdColors.warn
                                    : VdColors.dim,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 28,
                child: _hovered
                    ? IconButton(
                        tooltip: 'Remove from the project',
                        icon: const Icon(Icons.close, size: 15),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        onPressed: widget.onRemove,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "0:12 · 1920×1080" — the two things that decide where a clip can go.
String _subtitle(MediaProbe probe) {
  final parts = <String>[
    // A sticker's length is one loop rather than a limit, so printing it would
    // say "0:01" about a clip somebody can drag out as far as they like — and
    // an APNG, whose container reports no length at all, would say "0:00".
    probe.kind == MediaKind.sticker ? 'loops' : shortDuration(probe.duration),
  ];
  if (probe.hasVideo) {
    parts.add('${probe.displayWidth}×${probe.displayHeight}');
  } else {
    parts.add('audio');
  }
  return parts.join(' · ');
}

/// m:ss, or h:mm:ss past an hour. Rounded, because the bin is for recognising
/// a clip, not for cutting one.
String shortDuration(Tick duration) {
  final totalSeconds = duration.raw ~/ Timebase.project.ticksPerSecond;
  final seconds = totalSeconds % 60;
  final minutes = (totalSeconds ~/ 60) % 60;
  final hours = totalSeconds ~/ 3600;
  String two(int v) => v.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${two(minutes)}:${two(seconds)}'
      : '$minutes:${two(seconds)}';
}

/// The asset's picture, once the cache has decoded one.
///
/// Stateful because the image belongs to the cache, which may evict and
/// dispose it at any moment: this holds a clone for as long as it is painting
/// one, so a bin scrolled past its capacity cannot paint a disposed image.
class _Thumbnail extends StatefulWidget {
  const _Thumbnail({
    required this.asset,
    required this.thumbnails,
    required this.missing,
  });

  final MediaAsset asset;
  final ThumbnailCache thumbnails;
  final bool missing;

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  ui.Image? _clone;

  @override
  void initState() {
    super.initState();
    widget.thumbnails.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(_Thumbnail old) {
    super.didUpdateWidget(old);
    if (old.thumbnails != widget.thumbnails) {
      old.thumbnails.removeListener(_sync);
      widget.thumbnails.addListener(_sync);
    }
    if (old.asset.id != widget.asset.id) _release();
    _sync();
  }

  void _sync() {
    if (!mounted) return;
    if (!widget.missing) widget.thumbnails.request(widget.asset);
    final image = widget.thumbnails.imageOf(widget.asset.id);
    if (image == null || _clone != null) return;
    setState(() => _clone = image.clone());
  }

  void _release() {
    _clone?.dispose();
    _clone = null;
  }

  @override
  void dispose() {
    widget.thumbnails.removeListener(_sync);
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _clone;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: ColoredBox(
        color: Colors.black,
        child: image != null && !widget.missing
            // Contain, not cover. The engine goes to some trouble to give the
            // thumbnail the source's *display* shape; cropping it back to the
            // box would throw that away and make a portrait clip look
            // landscape in the one place the user scans for it.
            ? RawImage(image: image, fit: BoxFit.contain)
            : Center(child: Icon(_placeholder(), size: 15, color: VdColors.dim)),
      ),
    );
  }

  IconData _placeholder() {
    if (widget.missing) return Icons.link_off;
    if (!widget.asset.probe.hasVideo) return Icons.graphic_eq;
    return switch (widget.thumbnails.stateOf(widget.asset.id)) {
      ThumbnailState.failed => Icons.broken_image_outlined,
      ThumbnailState.none => Icons.graphic_eq,
      _ => Icons.movie_outlined,
    };
  }
}
