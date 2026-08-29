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
          },
      ],
    };

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
