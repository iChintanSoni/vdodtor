// The application icon, drawn from the numbers in this file rather than
// vendored as a picture somebody exported once.
//
// This is `tools/make_luts.dart`'s argument pointed at the icon. A `.png`
// dropped into the asset catalogue is a file nobody can argue with: it cannot
// be re-rendered at a size Apple adds next year, it cannot be re-tinted when
// the palette moves, and the source it came out of lives in somebody's design
// tool rather than in this repository. Sixty lines of geometry can be read,
// disagreed with and re-run — and, like the looks and the sample footage, what
// ships inside a product sold without an account is then unambiguously ours to
// sell.
//
// The mark is the app's own timeline: three clip bars in the colours
// `VdColors` paints tracks with, cut under the playhead, which is drawn as the
// line-and-triangle `timeline_painter.dart` draws. So the icon is a picture of
// the thing the app actually is — multi-track — rather than a play triangle
// that would fit any of the competitors in the brief just as well.
//
// The mark is drawn at three levels of detail, because one geometry scaled down
// to 16 px is Apple's own "don't" and it is right: a 40-unit cut is a third of a
// pixel there, so the detail is not lost, it is *noise*. Under 64 px the overlay
// lane and the cut go, leaving two fatter lanes; under 32 px the playhead's head
// goes too and its line roughly doubles in width, because a line under a pixel
// and a half wide stops being red and becomes a grey smudge. All three are the
// same idea drawn at the size it survives.
//
// Run from the repository root:
//
//   dart run tools/make_icon.dart
//
// It writes every file `AppIcon.appiconset/Contents.json` names.
// `app/test/app/icon_test.dart` renders the same geometry again and compares it
// to what is on disk, which is `about_test.dart`'s rule — generated, and then
// checked against what actually shipped.

import 'dart:io';
import 'dart:typed_data';

/// The sizes `AppIcon.appiconset/Contents.json` names, deduplicated: macOS
/// asks for seven files across ten slots, because @2x of one size is the file
/// for the next one up.
const List<int> iconSizes = <int>[16, 32, 64, 128, 256, 512, 1024];

/// Everything below is measured in this square, whatever is being rendered
/// into. The mark is one design, not seven, so every number here is a fraction
/// of the icon rather than a count of pixels — the same rule the caption and
/// the shape renderers take in the engine.
const double _design = 1024;

/// Under this many pixels the overlay lane and the cut stop being detail and
/// start being noise; under [_tinyUnder] the playhead's head goes the same way.
/// See the header.
const int _simpleUnder = 64;
const int _tinyUnder = 32;

// --- ink ---------------------------------------------------------------

/// The icon's palette.
///
/// The hues are the timeline's own, one step brighter. `VdColors` is muted on
/// purpose — it sits next to the user's footage all day — but an icon is seen
/// at 32 px against a Finder window, where muted reads as grey. The playhead is
/// the exception and is `VdColors.playhead` exactly: it is the one thing in
/// this product allowed to be loud, and it should be the same loud everywhere.
abstract final class _Ink {
  static final bodyTop = _Rgba.hex(0x272C35);
  static final bodyBottom = _Rgba.hex(0x13151A);
  static final rim = _Rgba.hex(0xFFFFFF);
  static final shadow = _Rgba.hex(0x000000);
  static final video = _Rgba.hex(0x4E86E0);
  static final overlay = _Rgba.hex(0x7A6BD0);
  static final audio = _Rgba.hex(0x45A688);
  static final playhead = _Rgba.hex(0xFF5C5C);
}

class _Rgba {
  const _Rgba(this.r, this.g, this.b, this.a);

  factory _Rgba.hex(int rgb, [double a = 1]) => _Rgba(
        ((rgb >> 16) & 0xFF) / 255,
        ((rgb >> 8) & 0xFF) / 255,
        (rgb & 0xFF) / 255,
        a,
      );

  final double r, g, b, a;

  _Rgba withAlpha(double alpha) => _Rgba(r, g, b, alpha);

  static _Rgba lerp(_Rgba from, _Rgba to, double t) => _Rgba(
        from.r + (to.r - from.r) * t,
        from.g + (to.g - from.g) * t,
        from.b + (to.b - from.b) * t,
        from.a + (to.a - from.a) * t,
      );
}

// --- shapes ------------------------------------------------------------

/// A shape is an inside-test and a bounding box, and nothing else.
///
/// Which is all the rasteriser below needs, and it means a new shape costs one
/// function — no path builder, no edge list, no winding rule to get wrong.
/// Antialiasing comes out of asking the test more often per pixel, so every
/// shape is antialiased by construction and none of them has to know it.
class _Shape {
  const _Shape(this.inside, this.left, this.top, this.right, this.bottom);

  final bool Function(double x, double y) inside;
  final double left, top, right, bottom;

  _Shape translated(double dx, double dy) => _Shape(
        (x, y) => inside(x - dx, y - dy),
        left + dx,
        top + dy,
        right + dx,
        bottom + dy,
      );

  /// This shape with [other] taken out of it — how the rim is drawn, as the
  /// squircle minus the same squircle a little smaller.
  _Shape without(_Shape other) => _Shape(
        (x, y) => inside(x, y) && !other.inside(x, y),
        left,
        top,
        right,
        bottom,
      );
}

/// The macOS icon shape: a superellipse with exponent 5.
///
/// Not a rounded rectangle. A rounded rectangle's corner joins the straight
/// edge at a curvature discontinuity that the eye reads as a flat spot, which
/// is why every platform that cares moved to a continuous corner; exponent 5 is
/// the standard approximation of the one macOS uses, and it is exact enough
/// that the icon sits correctly beside the system's own.
_Shape _squircle(double cx, double cy, double r) {
  double p5(double v) {
    final square = v * v;
    return square * square * v;
  }

  return _Shape(
    (x, y) => p5((x - cx).abs() / r) + p5((y - cy).abs() / r) <= 1,
    cx - r,
    cy - r,
    cx + r,
    cy + r,
  );
}

_Shape _roundRect(double x0, double y0, double x1, double y1, double radius) {
  final r = radius;
  return _Shape(
    (x, y) {
      if (x < x0 || x > x1 || y < y0 || y > y1) return false;
      final qx = x < x0 + r
          ? x0 + r - x
          : x > x1 - r
              ? x - (x1 - r)
              : 0.0;
      final qy = y < y0 + r
          ? y0 + r - y
          : y > y1 - r
              ? y - (y1 - r)
              : 0.0;
      return qx * qx + qy * qy <= r * r;
    },
    x0,
    y0,
    x1,
    y1,
  );
}

/// The playhead's head, flat side up and pointing down into the line — the
/// path `TimelinePainter._paintPlayhead` draws, at the proportions it draws it.
_Shape _downTriangle(double cx, double top, double halfWidth, double height) {
  final ax = cx - halfWidth, ay = top;
  final bx = cx + halfWidth, by = top;
  final px = cx, py = top + height;

  double edge(double x, double y, double x0, double y0, double x1, double y1) =>
      (x1 - x0) * (y - y0) - (y1 - y0) * (x - x0);

  return _Shape(
    (x, y) {
      final e0 = edge(x, y, ax, ay, bx, by);
      final e1 = edge(x, y, bx, by, px, py);
      final e2 = edge(x, y, px, py, ax, ay);
      return (e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0);
    },
    cx - halfWidth,
    top,
    cx + halfWidth,
    top + height,
  );
}

// --- the canvas --------------------------------------------------------

/// A premultiplied RGBA canvas that antialiases by area-sampling each shape.
///
/// The sample count rises as the icon gets smaller so the *sampling* grid stays
/// roughly constant — a 16 px icon is 16x16 output pixels over the same design,
/// so it needs 16x16 samples inside each of them to describe the same edges.
/// That makes a small icon exactly the area-average of the large one, which is
/// the correct downscale, arrived at without ever allocating the large one.
class _Canvas {
  _Canvas(this.size)
      : _px = Float64List(size * size * 4),
        _unit = _design / size,
        _samples = (4096 ~/ size).clamp(4, 16);

  final int size;
  final Float64List _px;
  final double _unit;
  final int _samples;

  void fill(_Shape shape, _Rgba Function(double x, double y) paint) {
    _forEach(shape, (index, x, y, coverage) {
      final colour = paint(x, y);
      _blend(index, colour, colour.a * coverage);
    });
  }

  void fillSolid(_Shape shape, _Rgba colour) =>
      fill(shape, (_, __) => colour);

  /// How much of each pixel [shape] covers — the input to the drop shadow,
  /// which is this blurred and then painted black.
  Float64List coverage(_Shape shape) {
    final mask = Float64List(size * size);
    _forEach(shape, (index, _, __, coverage) => mask[index >> 2] = coverage);
    return mask;
  }

  void shade(Float64List mask, _Rgba colour) {
    for (var p = 0; p < size * size; p++) {
      final m = mask[p];
      if (m > 0) _blend(p * 4, colour, colour.a * m);
    }
  }

  void _forEach(
    _Shape shape,
    void Function(int index, double x, double y, double coverage) at,
  ) {
    final x0 = _clampPixel((shape.left / _unit).floor());
    final x1 = _clampPixel((shape.right / _unit).ceil() + 1);
    final y0 = _clampPixel((shape.top / _unit).floor());
    final y1 = _clampPixel((shape.bottom / _unit).ceil() + 1);

    for (var py = y0; py < y1; py++) {
      for (var px = x0; px < x1; px++) {
        final coverage = _cover(shape, px, py);
        if (coverage <= 0) continue;
        at(
          (py * size + px) * 4,
          (px + 0.5) * _unit,
          (py + 0.5) * _unit,
          coverage,
        );
      }
    }
  }

  double _cover(_Shape shape, int px, int py) {
    var hits = 0;
    for (var j = 0; j < _samples; j++) {
      final y = (py + (j + 0.5) / _samples) * _unit;
      for (var i = 0; i < _samples; i++) {
        final x = (px + (i + 0.5) / _samples) * _unit;
        if (shape.inside(x, y)) hits++;
      }
    }
    return hits / (_samples * _samples);
  }

  int _clampPixel(int v) => v < 0 ? 0 : (v > size ? size : v);

  void _blend(int i, _Rgba c, double a) {
    if (a <= 0) return;
    final inv = 1 - a;
    _px[i] = c.r * a + _px[i] * inv;
    _px[i + 1] = c.g * a + _px[i + 1] * inv;
    _px[i + 2] = c.b * a + _px[i + 2] * inv;
    _px[i + 3] = a + _px[i + 3] * inv;
  }

  /// The canvas as straight-alpha RGBA8, which is what PNG stores.
  Uint8List toRgba() {
    final out = Uint8List(size * size * 4);
    for (var p = 0; p < size * size; p++) {
      final a = _px[p * 4 + 3];
      if (a <= 0) continue;
      out[p * 4] = _byte(_px[p * 4] / a);
      out[p * 4 + 1] = _byte(_px[p * 4 + 1] / a);
      out[p * 4 + 2] = _byte(_px[p * 4 + 2] / a);
      out[p * 4 + 3] = _byte(a);
    }
    return out;
  }

  static int _byte(double v) => (v.clamp(0.0, 1.0) * 255).round();
}

/// Three box passes, which is close enough to a Gaussian that nobody can tell
/// and is O(1) per pixel whatever the radius.
Float64List _blur(Float64List source, int size, int radius) {
  if (radius <= 0) return source;
  var a = Float64List.fromList(source);
  final b = Float64List(source.length);
  for (var pass = 0; pass < 3; pass++) {
    _box(a, b, size, radius, rows: true);
    _box(b, a, size, radius, rows: false);
  }
  return a;
}

void _box(
  Float64List src,
  Float64List dst,
  int size,
  int radius, {
  required bool rows,
}) {
  final width = 2 * radius + 1;
  int at(int line, int i) {
    final j = i < 0 ? 0 : (i >= size ? size - 1 : i);
    return rows ? line * size + j : j * size + line;
  }

  for (var line = 0; line < size; line++) {
    var sum = 0.0;
    for (var i = -radius; i <= radius; i++) {
      sum += src[at(line, i)];
    }
    for (var i = 0; i < size; i++) {
      dst[at(line, i)] = sum / width;
      sum += src[at(line, i + radius + 1)] - src[at(line, i - radius)];
    }
  }
}

// --- the mark ----------------------------------------------------------

/// One lane of the mark: a bar in the colour the timeline paints that kind of
/// track with.
class _Lane {
  const _Lane(this.x0, this.x1, this.colour);
  final double x0, x1;
  final _Rgba colour;
}

class _Mark {
  const _Mark({
    required this.lanes,
    required this.laneHeight,
    required this.laneGap,
    required this.laneRadius,
    required this.cutWidth,
    required this.playheadWidth,
    required this.headWidth,
    required this.headHeight,
    required this.overhangTop,
    required this.overhangBottom,
  });

  final List<_Lane> lanes;
  final double laneHeight, laneGap, laneRadius;

  /// The gap taken out of the top lane, on the playhead — the one place the
  /// icon says the app cuts. Zero on the simplified mark, where it would be a
  /// third of a pixel.
  final double cutWidth;
  final double playheadWidth, headWidth, headHeight;
  final double overhangTop, overhangBottom;
}

_Mark _markFor(int size) {
  if (size < _tinyUnder) {
    return _Mark(
      lanes: <_Lane>[
        _Lane(150, 874, _Ink.video),
        _Lane(150, 780, _Ink.audio),
      ],
      laneHeight: 190,
      laneGap: 104,
      laneRadius: 44,
      cutWidth: 0,
      playheadWidth: 112,
      headWidth: 0,
      headHeight: 0,
      overhangTop: 96,
      overhangBottom: 96,
    );
  }
  if (size < _simpleUnder) {
    return _Mark(
      lanes: <_Lane>[
        _Lane(178, 846, _Ink.video),
        _Lane(178, 762, _Ink.audio),
      ],
      laneHeight: 176,
      laneGap: 92,
      laneRadius: 40,
      cutWidth: 0,
      playheadWidth: 58,
      headWidth: 216,
      headHeight: 76,
      overhangTop: 118,
      overhangBottom: 94,
    );
  }
  return _Mark(
    lanes: <_Lane>[
      _Lane(196, 828, _Ink.video),
      _Lane(300, 760, _Ink.overlay),
      _Lane(196, 700, _Ink.audio),
    ],
    laneHeight: 108,
    laneGap: 48,
    laneRadius: 22,
    cutWidth: 40,
    playheadWidth: 30,
    headWidth: 158,
    headHeight: 54,
    overhangTop: 104,
    overhangBottom: 84,
  );
}

/// Where the playhead stands. The middle, so the mark is symmetrical about the
/// one element that is allowed to be loud.
const double _playheadX = _design / 2;

/// The icon at [size], as straight-alpha RGBA8.
Uint8List renderIcon(int size) {
  final canvas = _Canvas(size);

  // Apple's grid: an 824-square shape inside a 1024 canvas, lifted a little so
  // the shadow it casts has somewhere to go.
  //
  // Except at 16 px, where it fills nearly the whole canvas and casts nothing.
  // A shadow there is one blurred pixel of grey laid over a mark that is only
  // seven pixels tall, and the margin it was making room for is a fifth of the
  // width. Apple's own small icons are optically adjusted the same way; the
  // grid is a starting point rather than a rule.
  final tiny = size < _tinyUnder;
  final body = tiny ? 456.0 : 412.0;
  const cx = _design / 2;
  final cy = _design / 2 - (tiny ? 0.0 : 8.0);

  final shape = _squircle(cx, cy, body);

  if (!tiny) {
    // The shadow, offset down and blurred. Subtle: macOS stopped drawing one
    // for you, and an icon that draws itself a heavy one looks like it is
    // from 2013.
    final shadowRadius = (size * 18 / _design).round().clamp(1, 1 << 20);
    canvas.shade(
      _blur(canvas.coverage(shape.translated(0, 16)), size, shadowRadius),
      _Ink.shadow.withAlpha(0.32),
    );
  }

  // The body: a vertical gradient, dark, because this is a dark app and an
  // icon that is a different colour from the window it opens is two products.
  final top = cy - body;
  final height = body * 2;
  canvas.fill(
    shape,
    (_, y) => _Rgba.lerp(
      _Ink.bodyTop,
      _Ink.bodyBottom,
      ((y - top) / height).clamp(0.0, 1.0),
    ),
  );

  // A rim light along the top edge and nowhere else, which is what a physical
  // object under a room's lighting does and what stops the squircle reading as
  // a flat hole.
  canvas.fill(
    shape.without(_squircle(cx, cy, body - 3.5)),
    (_, y) {
      final t = ((y - top) / height).clamp(0.0, 1.0);
      final falloff = (1 - t) * (1 - t) * (1 - t);
      return _Ink.rim.withAlpha(0.16 * falloff);
    },
  );

  _drawMark(canvas, _markFor(size), cy + _markDrop);
  return canvas.toRgba();
}

/// How far below the shape's own centre the mark hangs.
///
/// The playhead's head is the heaviest thing in the drawing and it is at the
/// top, so a mark centred arithmetically reads as sitting high. Optical
/// centring is the whole of this number.
const double _markDrop = 16;

void _drawMark(_Canvas canvas, _Mark mark, double centreY) {
  final block = mark.lanes.length * mark.laneHeight +
      (mark.lanes.length - 1) * mark.laneGap;
  final blockTop = centreY - block / 2;

  final lineTop = blockTop - mark.overhangTop;
  final lineBottom = blockTop + block + mark.overhangBottom;

  for (var i = 0; i < mark.lanes.length; i++) {
    final lane = mark.lanes[i];
    final y0 = blockTop + i * (mark.laneHeight + mark.laneGap);
    final y1 = y0 + mark.laneHeight;

    // The cut goes in the top lane, because that is the magnetic one and the
    // one an edit actually happens on.
    if (i == 0 && mark.cutWidth > 0) {
      final half = mark.cutWidth / 2;
      canvas.fillSolid(
        _roundRect(lane.x0, y0, _playheadX - half, y1, mark.laneRadius),
        lane.colour,
      );
      canvas.fillSolid(
        _roundRect(_playheadX + half, y0, lane.x1, y1, mark.laneRadius),
        lane.colour,
      );
    } else {
      canvas.fillSolid(
        _roundRect(lane.x0, y0, lane.x1, y1, mark.laneRadius),
        lane.colour,
      );
    }
  }

  final half = mark.playheadWidth / 2;
  canvas.fillSolid(
    _roundRect(
      _playheadX - half,
      lineTop,
      _playheadX + half,
      lineBottom,
      half,
    ),
    _Ink.playhead,
  );
  if (mark.headHeight > 0) {
    canvas.fillSolid(
      _downTriangle(_playheadX, lineTop, mark.headWidth / 2, mark.headHeight),
      _Ink.playhead,
    );
  }
}

// --- PNG ---------------------------------------------------------------

/// A PNG writer, in about sixty lines, for `lib/pro/ed25519.dart`'s reason: a
/// dependency here would be a third party in the path between this repository
/// and the icon of the thing it ships, and the format's uncompressed 8-bit RGBA
/// case is small enough that writing it is cheaper than trusting one.
Uint8List encodePng(int size, Uint8List rgba) {
  final stride = size * 4;
  final raw = Uint8List(size * (1 + stride));
  for (var y = 0; y < size; y++) {
    // Filter 0 (None). Every other filter type exists to help the compressor,
    // and this picture is mostly flat colour that deflate already handles.
    raw[y * (1 + stride)] = 0;
    raw.setRange(
      y * (1 + stride) + 1,
      y * (1 + stride) + 1 + stride,
      rgba,
      y * stride,
    );
  }

  final out = BytesBuilder();
  out.add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder()
    ..add(_be32(size))
    ..add(_be32(size))
    ..add(<int>[8, 6, 0, 0, 0]); // 8-bit, truecolour with alpha, no interlace
  out.add(_chunk('IHDR', ihdr.takeBytes()));
  out.add(_chunk(
    'IDAT',
    Uint8List.fromList(ZLibCodec(level: 9).encode(raw)),
  ));
  out.add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

List<int> _be32(int v) => <int>[
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];

Uint8List _chunk(String type, Uint8List data) {
  final body = BytesBuilder()
    ..add(type.codeUnits)
    ..add(data);
  final bytes = body.takeBytes();
  return Uint8List.fromList(<int>[
    ..._be32(data.length),
    ...bytes,
    ..._be32(_crc32(bytes)),
  ]);
}

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

int _crc32(Uint8List bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

// --- main --------------------------------------------------------------

const String _defaultOut =
    'app/macos/Runner/Assets.xcassets/AppIcon.appiconset';

/// What the file for a given size is called, which `Contents.json` has to
/// agree with and `app/test/app/icon_test.dart` checks that it does.
String iconFileName(int size) => 'app_icon_$size.png';

void main(List<String> args) {
  var out = _defaultOut;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--out' && i + 1 < args.length) out = args[i + 1];
  }

  final directory = Directory(out);
  if (!directory.existsSync()) {
    stderr.writeln('no such directory: $out');
    stderr.writeln('run this from the repository root, or pass --out');
    exit(2);
  }

  for (final size in iconSizes) {
    final file = File('$out/${iconFileName(size)}');
    file.writeAsBytesSync(encodePng(size, renderIcon(size)));
    stdout.writeln('${file.path}  ${file.lengthSync()} bytes');
  }
}
