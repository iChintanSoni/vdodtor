import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/engine/timeline_sync.dart';
import 'package:vdodtor/model/clip.dart';
import 'package:vdodtor/model/time.dart';
import 'package:vdodtor/model/track.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

import '../fixtures.dart';

const textTrackId = 'tr-text';

Clip captionOf(
  String id, {
  required Tick start,
  required Tick duration,
  ClipText text = const ClipText(text: 'Hello'),
}) =>
    Clip.caption(id: id, start: start, duration: duration, text: text);

void main() {
  group('a caption is a clip with no file', () {
    test('and says so', () {
      final clip = captionOf('t1', start: Tick.zero, duration: secs(3));
      expect(clip.isText, isTrue);
      expect(clip.mediaId, isNull);
      expect(clip.text!.text, 'Hello');
    });

    test('an ordinary clip is not one', () {
      final clip = clipOf('c1', 'm1', start: Tick.zero, duration: secs(3));
      expect(clip.isText, isFalse);
      expect(clip.text, isNull);
    });

    test('a clip cannot be both', () {
      expect(
        () => Clip(
          id: 'x',
          mediaId: 'm1',
          start: Tick.zero,
          duration: secs(1),
          text: const ClipText(text: 'no'),
        ),
        throwsA(isA<AssertionError>()),
      );
    });

    test('nothing bounds how long it may be', () {
      // The same answer an image gets, and for a stronger reason: there is no
      // source to run out of at all.
      final clip = captionOf('t1', start: Tick.zero, duration: secs(3));
      expect(maxDurationFor(clip, null), Tick.zero);
    });

    test('trimming it keeps the caption', () {
      final clip = captionOf('t1', start: Tick.zero, duration: secs(3));
      final trimmed = clip.trimTailBy(secs(2));
      expect(trimmed.duration, secs(5));
      expect(trimmed.text, clip.text);
    });

    test('and so does moving it', () {
      final clip = captionOf('t1', start: Tick.zero, duration: secs(3));
      expect(clip.movedTo(secs(9)).text, clip.text);
    });
  });

  group('ClipText', () {
    test('the default is white, centred and readable', () {
      const t = ClipText.plain;
      expect(t.color, 0xFFFFFFFF);
      expect(t.alignment, TextAlignment.center);
      expect(t.size, greaterThan(0));
      // The optional parts are off but still described, so turning one on does
      // not also mean guessing what shape it had.
      expect(t.hasShadow, isFalse);
      expect(t.hasBox, isFalse);
      expect(t.shadowBlur, greaterThan(0));
      expect(t.boxPadding, greaterThan(0));
    });

    test('alpha 0 is what switches the optional parts off', () {
      const t = ClipText(text: 'x', shadowColor: 0x00123456, boxColor: 0);
      expect(t.hasShadow, isFalse);
      expect(t.hasBox, isFalse);
      expect(const ClipText(text: 'x', shadowColor: 0x01000000).hasShadow,
          isTrue);
    });

    test('an outline needs a width as well as a colour', () {
      expect(const ClipText(text: 'x', strokeColor: 0xFF000000).hasStroke,
          isFalse);
      expect(
          const ClipText(text: 'x', strokeColor: 0xFF000000, strokeWidth: 0.1)
              .hasStroke,
          isTrue);
      expect(
          const ClipText(text: 'x', strokeColor: 0x00000000, strokeWidth: 0.1)
              .hasStroke,
          isFalse);
    });

    test('the label is the first line, and never blank', () {
      expect(const ClipText(text: 'One\nTwo').label, 'One');
      expect(const ClipText(text: '  spaced  ').label, 'spaced');
      expect(const ClipText(text: '').label, 'Text');
      expect(const ClipText(text: '\n\n').label, 'Text');
    });

    test('clamping pulls everything inside the sliders', () {
      const wild = ClipText(
        text: 'x',
        size: 99,
        strokeWidth: 99,
        shadowOffsetX: -99,
        shadowBlur: 99,
        boxPadding: 99,
        boxRadius: 99,
        letterSpacing: 99,
        lineSpacing: 99,
        maxWidth: 99,
      );
      final t = wild.clamped();
      expect(t.size, ClipText.maxSize);
      expect(t.strokeWidth, ClipText.maxStrokeWidth);
      expect(t.shadowOffsetX, -ClipText.maxShadowOffset);
      expect(t.shadowBlur, ClipText.maxShadowBlur);
      expect(t.boxPadding, ClipText.maxBoxPadding);
      expect(t.boxRadius, ClipText.maxBoxRadius);
      expect(t.letterSpacing, ClipText.maxLetterSpacing);
      expect(t.lineSpacing, ClipText.maxLineSpacing);
      expect(t.maxWidth, 1.0);
      // The words themselves are never touched by a clamp.
      expect(t.text, 'x');
    });

    test('clamping leaves a sane caption alone', () {
      const t = ClipText(text: 'x', size: 0.1, lineSpacing: 1.2);
      expect(t.clamped(), t);
    });

    test('equality is by value, so an edit that changes nothing is a no-op',
        () {
      const a = ClipText(text: 'x', size: 0.1);
      const b = ClipText(text: 'x', size: 0.1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.copyWith(size: 0.2), isNot(b));
      expect(a.copyWith(text: 'y'), isNot(b));
      expect(a.copyWith(alignment: TextAlignment.left), isNot(b));
    });
  });

  group('a caption reaching the engine', () {
    Track textTrack(List<Clip> clips, {bool hidden = false}) => Track.of(
          id: textTrackId,
          kind: TrackKind.text,
          name: 'Text 1',
          clips: clips,
          hidden: hidden,
        );

    test('crosses as words rather than as a path', () {
      final project = emptyProject().addTrack(textTrack([
        captionOf('t1', start: secs(1), duration: secs(3)),
      ]));

      final timeline = engineTimelineFor(project);
      expect(timeline.clips, hasLength(1));
      final clip = timeline.clips.single;
      expect(clip.path, isNull);
      expect(clip.text!.text, 'Hello');
      expect(clip.startTicks, secs(1).raw);
      expect(clip.durationTicks, secs(3).raw);
      // Silent, and stretched: the raster is made at the size of the frame, so
      // there is nothing to fit and nothing to hear.
      expect(clip.gain, 0);
      expect(clip.fit, FitMode.stretch);
    });

    test('every measurement crosses as the fraction it was stored as', () {
      const styled = ClipText(
        text: 'Styled',
        font: 'Anton',
        size: 0.15,
        color: 0xFFFF0000,
        strokeColor: 0xFF00FF00,
        strokeWidth: 0.05,
        shadowColor: 0x80000000,
        shadowOffsetX: 0.01,
        shadowOffsetY: 0.02,
        shadowBlur: 0.03,
        boxColor: 0x99000000,
        boxPadding: 0.4,
        boxRadius: 0.2,
        letterSpacing: 0.06,
        lineSpacing: 1.4,
        maxWidth: 0.7,
        alignment: TextAlignment.right,
      );
      final project = emptyProject().addTrack(textTrack([
        captionOf('t1', start: Tick.zero, duration: secs(2), text: styled),
      ]));

      final text = engineTimelineFor(project).clips.single.text!;
      expect(text.font, 'Anton');
      expect(text.size, 0.15);
      expect(text.color, 0xFFFF0000);
      expect(text.strokeColor, 0xFF00FF00);
      expect(text.strokeWidth, 0.05);
      expect(text.shadowColor, 0x80000000);
      expect(text.shadowDx, 0.01);
      expect(text.shadowDy, 0.02);
      expect(text.shadowBlur, 0.03);
      expect(text.boxColor, 0x99000000);
      expect(text.boxPadding, 0.4);
      expect(text.boxRadius, 0.2);
      expect(text.letterSpacing, 0.06);
      expect(text.lineSpacing, 1.4);
      expect(text.maxWidth, 0.7);
      expect(text.alignment, EngineTextAlign.right);
    });

    test('carries the clip transform, so it can be placed', () {
      final project = emptyProject().addTrack(textTrack([
        captionOf('t1', start: Tick.zero, duration: secs(2)).copyWith(
          transform: const ClipTransform(offsetY: 0.35, scale: 1.5,
              opacity: 0.5),
        ),
      ]));

      final clip = engineTimelineFor(project).clips.single;
      expect(clip.transform.offsetY, 0.35);
      expect(clip.transform.scale, 1.5);
      expect(clip.opacity, 0.5);
    });

    test('a hidden text lane sends nothing', () {
      final project = emptyProject().addTrack(textTrack(
        [captionOf('t1', start: Tick.zero, duration: secs(2))],
        hidden: true,
      ));
      expect(engineTimelineFor(project).clips, isEmpty);
    });

    test('a disabled caption sends nothing', () {
      final project = emptyProject().addTrack(textTrack([
        captionOf('t1', start: Tick.zero, duration: secs(2))
            .copyWith(enabled: false),
      ]));
      expect(engineTimelineFor(project).clips, isEmpty);
    });

    test('a caption composites above the clips under it', () {
      // List order is z-order, and a text lane is added above the visual ones.
      var project = emptyProject();
      project = project.updateTrack(
        mainTrackId,
        (t) => t.withClips(
            [clipOf('c1', 'm1', start: Tick.zero, duration: secs(4))]),
      );
      project = project.addTrack(
        textTrack([captionOf('t1', start: Tick.zero, duration: secs(2))]),
        at: project.insertIndexFor(TrackKind.text),
      );

      final clips = engineTimelineFor(project).clips;
      expect(clips, hasLength(2));
      expect(clips.first.path, isNotNull);
      expect(clips.last.text, isNotNull);
      expect(clips.last.track, greaterThan(clips.first.track));
    });
  });
}
