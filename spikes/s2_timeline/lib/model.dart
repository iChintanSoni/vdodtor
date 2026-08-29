// Timeline document model for the S2 spike.
//
// Time is integer ticks on a 120000/s timebase — never floating-point seconds.
// 120000 divides evenly by every rate the product supports, including the NTSC
// fractional ones:
//   24 -> 5000   25 -> 4800   30 -> 4000   60 -> 2000
//   23.976 -> 5005   29.97 -> 4004   59.94 -> 2002
// That exactness is the whole reason for the tick model, so the spike uses it.

import 'package:flutter/material.dart';

const int kTicksPerSecond = 120000;

int ticksFromSeconds(double s) => (s * kTicksPerSecond).round();
double secondsFromTicks(int t) => t / kTicksPerSecond;

/// Ticks per frame at [fps], exact for the rates the product supports.
int ticksPerFrame(double fps) => (kTicksPerSecond / fps).round();

enum TrackKind { video, overlay, audio }

class Clip {
  Clip({
    required this.id,
    required this.start,
    required this.duration,
    required this.label,
    required this.color,
  });

  final String id;
  int start;      // ticks from timeline zero
  int duration;   // ticks
  final String label;
  final Color color;

  int get end => start + duration;

  Clip copy() => Clip(
        id: id, start: start, duration: duration, label: label, color: color);
}

class Track {
  Track({required this.name, required this.kind, required this.clips});

  final String name;
  final TrackKind kind;
  final List<Clip> clips;

  /// The main video track is magnetic: no gaps, deletes ripple closed.
  bool get magnetic => kind == TrackKind.video;

  void sortByStart() => clips.sort((a, b) => a.start.compareTo(b.start));

  /// Repacks clips end-to-end from zero. Only meaningful on a magnetic track.
  void repack() {
    sortByStart();
    var cursor = 0;
    for (final c in clips) {
      c.start = cursor;
      cursor += c.duration;
    }
  }
}

class TimelineDoc {
  TimelineDoc(this.tracks);
  final List<Track> tracks;

  int get durationTicks {
    var maxEnd = 0;
    for (final t in tracks) {
      for (final c in t.clips) {
        if (c.end > maxEnd) maxEnd = c.end;
      }
    }
    return maxEnd;
  }

  /// Every clip edge except [except]'s — the snap candidates.
  List<int> snapEdges({Clip? except}) {
    final edges = <int>[0];
    for (final t in tracks) {
      for (final c in t.clips) {
        if (identical(c, except)) continue;
        edges..add(c.start)..add(c.end);
      }
    }
    return edges;
  }
}

/// Demo document: a magnetic main track plus parallel overlay and audio tracks.
TimelineDoc buildDemoDoc({int clipsPerTrack = 8}) {
  const palette = [
    Color(0xFF4C8DF6), Color(0xFF57B894), Color(0xFFE0A458),
    Color(0xFFC46D8E), Color(0xFF8B7FD6), Color(0xFF4FB0C6),
  ];

  Track make(String name, TrackKind kind, int n, int seedGap) {
    final clips = <Clip>[];
    var cursor = kind == TrackKind.video ? 0 : ticksFromSeconds(0.5);
    for (var i = 0; i < n; i++) {
      final dur = ticksFromSeconds(1.2 + (i % 5) * 0.6);
      clips.add(Clip(
        id: '$name-$i',
        start: cursor,
        duration: dur,
        label: '${name.split(' ').first} $i',
        color: palette[(i + seedGap) % palette.length],
      ));
      cursor += dur + (kind == TrackKind.video ? 0 : ticksFromSeconds(0.3));
    }
    return Track(name: name, kind: kind, clips: clips);
  }

  return TimelineDoc([
    make('Main video', TrackKind.video, clipsPerTrack, 0),
    make('Overlay 1', TrackKind.overlay, (clipsPerTrack * 0.6).round(), 2),
    make('Overlay 2', TrackKind.overlay, (clipsPerTrack * 0.4).round(), 4),
    make('Music', TrackKind.audio, (clipsPerTrack * 0.3).round(), 1),
    make('Voiceover', TrackKind.audio, (clipsPerTrack * 0.3).round(), 3),
  ]);
}
