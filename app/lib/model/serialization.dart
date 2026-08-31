import 'dart:convert';

import 'clip.dart';
import 'media.dart';
import 'project.dart';
import 'time.dart';
import 'track.dart';

/// Raised when a project file cannot be read. Carries the field that failed so
/// the user gets something better than "invalid JSON".
final class ProjectDecodeException implements Exception {
  ProjectDecodeException(this.message, {this.path});

  final String message;

  /// Dotted path to the offending field, e.g. `tracks[1].clips[3].start`.
  final String? path;

  @override
  String toString() =>
      'ProjectDecodeException: $message${path == null ? '' : ' (at $path)'}';
}

/// Bumped whenever the on-disk shape changes in a way old readers cannot
/// handle. [decodeProject] refuses anything newer than it understands, and
/// migrates anything older.
const int kProjectSchemaVersion = 1;

/// Serialises a project to the canonical map form. Keys are ordered for stable
/// diffs; times are written as raw tick integers, never as seconds.
Map<String, Object?> projectToJson(Project p) => {
      'schema': kProjectSchemaVersion,
      'app': 'vdodtor',
      'id': p.id,
      'name': p.name,
      'timebase': p.timebase.ticksPerSecond,
      'format': {
        'width': p.format.width,
        'height': p.format.height,
        'frameRate': p.format.frameRate.toString(),
      },
      'media': [
        for (final asset in p.media.values) _assetToJson(asset),
      ],
      'tracks': [
        for (final t in p.tracks) _trackToJson(t),
      ],
    };

Map<String, Object?> _assetToJson(MediaAsset a) => {
      'id': a.id,
      'path': a.path,
      'displayName': a.displayName,
      if (a.bookmark != null) 'bookmark': a.bookmark,
      'probe': {
        'kind': a.probe.kind.name,
        'duration': a.probe.duration.raw,
        'width': a.probe.width,
        'height': a.probe.height,
        'frameRate': a.probe.frameRate.toString(),
        'variableFrameRate': a.probe.variableFrameRate,
        'rotationDegrees': a.probe.rotationDegrees,
        'pixelAspect': a.probe.pixelAspect.toString(),
        'hasVideo': a.probe.hasVideo,
        'hasAudio': a.probe.hasAudio,
        'audioChannels': a.probe.audioChannels,
        'audioSampleRate': a.probe.audioSampleRate,
        if (a.probe.videoCodec != null) 'videoCodec': a.probe.videoCodec,
        if (a.probe.audioCodec != null) 'audioCodec': a.probe.audioCodec,
      },
    };

Map<String, Object?> _trackToJson(Track t) => {
      'id': t.id,
      'kind': t.kind.name,
      'name': t.name,
      'muted': t.muted,
      'locked': t.locked,
      'hidden': t.hidden,
      'clips': [
        for (final c in t.clips)
          {
            'id': c.id,
            if (c.mediaId != null) 'mediaId': c.mediaId,
            'start': c.start.raw,
            'duration': c.duration.raw,
            'sourceIn': c.sourceIn.raw,
            if (c.label.isNotEmpty) 'label': c.label,
            if (!c.enabled) 'enabled': false,
            // Left out entirely when nothing was changed, which is almost
            // every clip. A project file should read like the edit that made
            // it, not like a dump of every field that exists.
            if (!c.transform.isIdentity)
              'transform': _transformToJson(c.transform),
            if (!c.audio.isUnity) 'audio': _audioToJson(c.audio),
            if (c.text != null) 'text': _textToJson(c.text!),
          },
      ],
    };

/// Only what differs from the identity, so a transform someone nudged in one
/// axis does not write out eleven numbers.
Map<String, Object?> _transformToJson(ClipTransform t) => {
      if (t.fit != ClipFit.blurFill) 'fit': t.fit.name,
      if (t.offsetX != 0) 'offsetX': t.offsetX,
      if (t.offsetY != 0) 'offsetY': t.offsetY,
      if (t.scale != 1) 'scale': t.scale,
      if (t.rotationDegrees != 0) 'rotation': t.rotationDegrees,
      if (t.cropLeft != 0) 'cropLeft': t.cropLeft,
      if (t.cropTop != 0) 'cropTop': t.cropTop,
      if (t.cropRight != 0) 'cropRight': t.cropRight,
      if (t.cropBottom != 0) 'cropBottom': t.cropBottom,
      if (t.opacity != 1) 'opacity': t.opacity,
      if (t.flipHorizontal) 'flipH': true,
      if (t.flipVertical) 'flipV': true,
    };

Map<String, Object?> _audioToJson(ClipAudio a) => {
      if (a.volume != 1) 'volume': a.volume,
      if (a.fadeIn.raw != 0) 'fadeIn': a.fadeIn.raw,
      if (a.fadeOut.raw != 0) 'fadeOut': a.fadeOut.raw,
      if (a.muted) 'muted': true,
      // Objects rather than pairs: the encoder indents either way, so the
      // compact form buys nothing and costs the reader the labels.
      if (a.points.isNotEmpty)
        'volumePoints': [
          for (final p in a.points) {'t': p.sourceTime.raw, 'v': p.value},
        ],
    };

/// A caption, in full.
///
/// The only part of a clip written out whole rather than as a diff against a
/// default. The others are properties of a clip that mostly nobody touched;
/// this one *is* the clip, and a file where a caption's colour is missing
/// because it happened to be white reads like a file that lost it.
Map<String, Object?> _textToJson(ClipText t) => {
      'text': t.text,
      if (t.font.isNotEmpty) 'font': t.font,
      'size': t.size,
      // Hex, because that is how anybody reading a project file thinks about a
      // colour, and a decimal 4294967295 is not a colour anyone recognises.
      'color': _colorToJson(t.color),
      'strokeColor': _colorToJson(t.strokeColor),
      'strokeWidth': t.strokeWidth,
      'shadowColor': _colorToJson(t.shadowColor),
      'shadowX': t.shadowOffsetX,
      'shadowY': t.shadowOffsetY,
      'shadowBlur': t.shadowBlur,
      'boxColor': _colorToJson(t.boxColor),
      'boxPadding': t.boxPadding,
      'boxRadius': t.boxRadius,
      'letterSpacing': t.letterSpacing,
      'lineSpacing': t.lineSpacing,
      'maxWidth': t.maxWidth,
      'align': t.alignment.name,
    };

String _colorToJson(int argb) =>
    '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0').toUpperCase()}';

/// `#AARRGGBB`, and only that. A colour that will not parse is an error rather
/// than a fallback: guessing black would silently rewrite the caption someone
/// wrote, and guessing white would do it just as silently in the other
/// direction.
int _colorFromJson(Map<String, Object?> json, String key, String at) {
  final value = json[key];
  if (value is num) return value.toInt() & 0xFFFFFFFF;
  if (value is String) {
    final parsed = int.tryParse(value.replaceFirst('#', ''), radix: 16);
    if (parsed != null) return parsed & 0xFFFFFFFF;
  }
  throw ProjectDecodeException('expected a #AARRGGBB colour, got $value',
      path: at);
}

ClipText _textFromJson(Map<String, Object?> json, String where) => ClipText(
      text: (json['text'] as String?) ?? '',
      font: (json['font'] as String?) ?? '',
      size: _double(json, 'size', 0.08),
      color: _colorFromJson(json, 'color', '$where.color'),
      strokeColor: _colorFromJson(json, 'strokeColor', '$where.strokeColor'),
      strokeWidth: _double(json, 'strokeWidth', 0),
      shadowColor: _colorFromJson(json, 'shadowColor', '$where.shadowColor'),
      shadowOffsetX: _double(json, 'shadowX', 0),
      shadowOffsetY: _double(json, 'shadowY', 0.04),
      shadowBlur: _double(json, 'shadowBlur', 0.06),
      boxColor: _colorFromJson(json, 'boxColor', '$where.boxColor'),
      boxPadding: _double(json, 'boxPadding', 0.25),
      boxRadius: _double(json, 'boxRadius', 0.15),
      letterSpacing: _double(json, 'letterSpacing', 0),
      lineSpacing: _double(json, 'lineSpacing', 1),
      maxWidth: _double(json, 'maxWidth', 0.9),
      alignment: json['align'] == null
          ? TextAlignment.center
          : _enum(TextAlignment.values, json, 'align', '$where.align'),
    );

ClipAudio _audioFromJson(Map<String, Object?> json, String where) => ClipAudio(
      volume: _double(json, 'volume', 1),
      fadeIn: Tick(_intOr(json, 'fadeIn', '$where.fadeIn', 0)),
      fadeOut: Tick(_intOr(json, 'fadeOut', '$where.fadeOut', 0)),
      muted: _bool(json, 'muted', false),
      points: _volumePointsFromJson(json, '$where.volumePoints'),
    );

/// The volume line, sorted on the way in.
///
/// Sorted here rather than trusted, because sortedness is the one thing every
/// reader of [ClipAudio.points] assumes and a hand-edited file is exactly
/// where it stops being true.
List<VolumePoint> _volumePointsFromJson(Map<String, Object?> json, String at) {
  final raw = json['volumePoints'];
  if (raw == null) return const [];
  if (raw is! List) throw ProjectDecodeException('expected a list', path: at);

  final points = <VolumePoint>[];
  for (var i = 0; i < raw.length; i++) {
    final p = _asMap(raw[i], '$at[$i]');
    points.add(VolumePoint(
      Tick(_int(p, 't', '$at[$i].t')),
      // Neither is optional. A point whose level went missing is not a point
      // at unity — it is a file that has lost something, and quietly inventing
      // a level would put the duck somewhere nobody drew it.
      _requiredDouble(p, 'v', '$at[$i].v').clamp(0.0, ClipAudio.maxVolume),
    ));
  }
  points.sort((a, b) => a.sourceTime.compareTo(b.sourceTime));
  return points;
}

ClipTransform _transformFromJson(Map<String, Object?> json, String where) =>
    ClipTransform(
      // A file written before fit modes existed gets the default, which is
      // the whole point of the default being the one most clips want.
      fit: json['fit'] == null
          ? ClipFit.blurFill
          : _enum(ClipFit.values, json, 'fit', '$where.fit'),
      offsetX: _double(json, 'offsetX', 0),
      offsetY: _double(json, 'offsetY', 0),
      scale: _double(json, 'scale', 1),
      rotationDegrees: _double(json, 'rotation', 0),
      cropLeft: _double(json, 'cropLeft', 0),
      cropTop: _double(json, 'cropTop', 0),
      cropRight: _double(json, 'cropRight', 0),
      cropBottom: _double(json, 'cropBottom', 0),
      opacity: _double(json, 'opacity', 1),
      flipHorizontal: _bool(json, 'flipH', false),
      flipVertical: _bool(json, 'flipV', false),
    );

double _double(Map<String, Object?> json, String key, double fallback) {
  final value = json[key];
  return value is num ? value.toDouble() : fallback;
}

/// A number that has to be there. Unlike [_double], absent is an error.
double _requiredDouble(Map<String, Object?> json, String key, String at) {
  final value = json[key];
  if (value is num) return value.toDouble();
  throw ProjectDecodeException('expected a number, got ${value.runtimeType}',
      path: at);
}

/// An integer that may be absent. Absent means [fallback]; present and not an
/// integer is still an error, unlike [_double]. These are tick counts, and a
/// fade that quietly became zero because its number was written as a string is
/// a fade that disappeared without anyone being told.
int _intOr(Map<String, Object?> json, String key, String at, int fallback) {
  if (json[key] == null) return fallback;
  return _int(json, key, at);
}

/// Rebuilds a project from [projectToJson]'s output.
Project projectFromJson(Map<String, Object?> json) {
  final schema = _int(json, 'schema', 'schema');
  if (schema > kProjectSchemaVersion) {
    throw ProjectDecodeException(
      'project was written by a newer version of vdodtor '
      '(schema $schema, this build understands $kProjectSchemaVersion)',
    );
  }

  final timebase = Timebase(_int(json, 'timebase', 'timebase'));
  final formatJson = _map(json, 'format', 'format');
  final format = ProjectFormat(
    width: _int(formatJson, 'width', 'format.width'),
    height: _int(formatJson, 'height', 'format.height'),
    frameRate: _rational(formatJson, 'frameRate', 'format.frameRate'),
  );

  final media = <String, MediaAsset>{};
  final mediaList = _list(json, 'media', 'media');
  for (var i = 0; i < mediaList.length; i++) {
    final asset = _assetFromJson(_asMap(mediaList[i], 'media[$i]'), 'media[$i]');
    media[asset.id] = asset;
  }

  final tracks = <Track>[];
  final trackList = _list(json, 'tracks', 'tracks');
  for (var i = 0; i < trackList.length; i++) {
    tracks.add(_trackFromJson(_asMap(trackList[i], 'tracks[$i]'), 'tracks[$i]'));
  }

  if (!timebase.divides(format.frameRate)) {
    throw ProjectDecodeException(
      'timebase ${timebase.ticksPerSecond}/s cannot represent '
      '${format.frameRate} fps exactly',
      path: 'format.frameRate',
    );
  }

  return Project(
    id: _string(json, 'id', 'id'),
    name: _string(json, 'name', 'name'),
    format: format,
    timebase: timebase,
    tracks: tracks,
    media: media,
  );
}

MediaAsset _assetFromJson(Map<String, Object?> json, String at) {
  final probeJson = _map(json, 'probe', '$at.probe');
  return MediaAsset(
    id: _string(json, 'id', '$at.id'),
    path: _string(json, 'path', '$at.path'),
    displayName: _string(json, 'displayName', '$at.displayName'),
    bookmark: json['bookmark'] as String?,
    probe: MediaProbe(
      kind: _enum(MediaKind.values, probeJson, 'kind', '$at.probe.kind'),
      duration: Tick(_int(probeJson, 'duration', '$at.probe.duration')),
      width: _int(probeJson, 'width', '$at.probe.width'),
      height: _int(probeJson, 'height', '$at.probe.height'),
      frameRate: _rational(probeJson, 'frameRate', '$at.probe.frameRate'),
      variableFrameRate: _bool(probeJson, 'variableFrameRate', false),
      rotationDegrees: _int(probeJson, 'rotationDegrees', '$at.probe.rotation'),
      // Absent in projects written before sample aspect was carried, and
      // square is what those files were being drawn as anyway.
      pixelAspect: probeJson.containsKey('pixelAspect')
          ? _rational(probeJson, 'pixelAspect', '$at.probe.pixelAspect')
          : Rational.one,
      hasVideo: _bool(probeJson, 'hasVideo', false),
      hasAudio: _bool(probeJson, 'hasAudio', false),
      audioChannels: _int(probeJson, 'audioChannels', '$at.probe.audioChannels'),
      audioSampleRate:
          _int(probeJson, 'audioSampleRate', '$at.probe.audioSampleRate'),
      videoCodec: probeJson['videoCodec'] as String?,
      audioCodec: probeJson['audioCodec'] as String?,
    ),
  );
}

Track _trackFromJson(Map<String, Object?> json, String at) {
  final clipList = _list(json, 'clips', '$at.clips');
  final clips = <Clip>[];
  for (var i = 0; i < clipList.length; i++) {
    final c = _asMap(clipList[i], '$at.clips[$i]');
    final where = '$at.clips[$i]';
    final duration = Tick(_int(c, 'duration', '$where.duration'));
    if (duration.raw <= 0) {
      throw ProjectDecodeException('clip duration must be positive',
          path: '$where.duration');
    }
    clips.add(Clip(
      id: _string(c, 'id', '$where.id'),
      mediaId: c['mediaId'] as String?,
      start: Tick(_int(c, 'start', '$where.start')),
      duration: duration,
      sourceIn: Tick(_int(c, 'sourceIn', '$where.sourceIn')),
      label: (c['label'] as String?) ?? '',
      enabled: _bool(c, 'enabled', true),
      transform: c['transform'] == null
          ? ClipTransform.identity
          : _transformFromJson(
              _asMap(c['transform'], '$where.transform'), '$where.transform'),
      // Clamped on the way in: a file can always claim a fade longer than the
      // clip carrying it, whether through a hand edit or a version of this
      // program that did not clamp.
      audio: c['audio'] == null
          ? ClipAudio.unity
          : _audioFromJson(_asMap(c['audio'], '$where.audio'), '$where.audio')
              .clampedTo(duration),
      // Clamped on the way in for the same reason a fade is: a file may claim
      // a size or a spacing this version has no slider for, and a caption that
      // cannot be edited is worse than one that opens slightly changed.
      text: c['text'] == null
          ? null
          : _textFromJson(_asMap(c['text'], '$where.text'), '$where.text')
              .clamped(),
    ));
  }

  clips.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < clips.length; i++) {
    if (clips[i].start < clips[i - 1].end) {
      throw ProjectDecodeException(
        'clips ${clips[i - 1].id} and ${clips[i].id} overlap',
        path: '$at.clips',
      );
    }
  }

  return Track.of(
    id: _string(json, 'id', '$at.id'),
    kind: _enum(TrackKind.values, json, 'kind', '$at.kind'),
    name: _string(json, 'name', '$at.name'),
    clips: clips,
    muted: _bool(json, 'muted', false),
    locked: _bool(json, 'locked', false),
    hidden: _bool(json, 'hidden', false),
  );
}

/// Pretty-printed so a project file stays diffable in version control.
String encodeProject(Project p) =>
    const JsonEncoder.withIndent('  ').convert(projectToJson(p));

Project decodeProject(String source) {
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException catch (e) {
    throw ProjectDecodeException('file is not valid JSON: ${e.message}');
  }
  return projectFromJson(_asMap(decoded, 'root'));
}

// --- field readers, each naming the path it failed at -----------------------

Map<String, Object?> _asMap(Object? value, String at) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  throw ProjectDecodeException('expected an object', path: at);
}

Map<String, Object?> _map(Map<String, Object?> json, String key, String at) =>
    _asMap(json[key], at);

List<Object?> _list(Map<String, Object?> json, String key, String at) {
  final v = json[key];
  if (v is List) return v;
  throw ProjectDecodeException('expected a list', path: at);
}

int _int(Map<String, Object?> json, String key, String at) {
  final v = json[key];
  if (v is int) return v;
  throw ProjectDecodeException('expected an integer, got ${v.runtimeType}',
      path: at);
}

String _string(Map<String, Object?> json, String key, String at) {
  final v = json[key];
  if (v is String) return v;
  throw ProjectDecodeException('expected a string, got ${v.runtimeType}',
      path: at);
}

bool _bool(Map<String, Object?> json, String key, bool fallback) {
  final v = json[key];
  return v is bool ? v : fallback;
}

Rational _rational(Map<String, Object?> json, String key, String at) {
  final raw = _string(json, key, at);
  try {
    return Rational.parse(raw);
  } on FormatException {
    throw ProjectDecodeException('"$raw" is not a rational like "30000/1001"',
        path: at);
  } on ArgumentError {
    throw ProjectDecodeException('"$raw" is not a valid rational', path: at);
  }
}

T _enum<T extends Enum>(
    List<T> values, Map<String, Object?> json, String key, String at) {
  final raw = _string(json, key, at);
  for (final v in values) {
    if (v.name == raw) return v;
  }
  throw ProjectDecodeException(
      '"$raw" is not one of ${values.map((v) => v.name).join(', ')}',
      path: at);
}
