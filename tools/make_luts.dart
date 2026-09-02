// Writes the looks vdodtor ships, into app/assets/luts/*.cube.
//
//   dart run tools/make_luts.dart
//
// The files are generated rather than vendored because a look that ships in a
// product sold without an account has to be one we are allowed to sell — and
// the `.cube` files people share are almost never licensed for that. Every
// look here is a formula, in this file, and the `.cube` is what that formula
// evaluates to.
//
// It also means the looks are *readable*. A vendored cube is a quarter of a
// million numbers nobody can review; this is thirty lines of arithmetic per
// look, and changing one is a diff somebody can argue with.
//
// **Why they are not five more sliders.** Everything vd_color.c does is affine
// on RGB, which is what lets it compose into one matrix. None of these are: a
// split-tone pushes the shadows one way and the highlights the other, a
// bleach bypass mixes a curve with its own luma, and a film curve is a curve.
// That is the whole reason a LUT exists — see vd_lut.h.

import 'dart:io';
import 'dart:math' as math;

/// Entries per axis.
///
/// 17 rather than 33 or 65. Every look here is smooth — no clipping, no
/// posterisation, nothing that changes fast between one lattice point and the
/// next — so trilinear between 17 points reproduces the formula to well under
/// a code of 8-bit output, and the file is an eighth the size. A look with a
/// hard edge in it would need more, and would be saying something about itself
/// by needing them.
const size = 17;

/// BT.709, the weights vd_color.c measures grey with. The same numbers here so
/// that a monochrome look and a fully desaturated grade agree about what grey
/// is.
const lumaR = 0.2126;
const lumaG = 0.7152;
const lumaB = 0.0722;

typedef Rgb = ({double r, double g, double b});

double luma(Rgb c) => lumaR * c.r + lumaG * c.g + lumaB * c.b;

double clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

Rgb rgb(double r, double g, double b) => (r: r, g: g, b: b);

Rgb mixRgb(Rgb a, Rgb b, double t) =>
    rgb(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t);

/// The contrast curve every look here leans on: a sigmoid through (0,0), (1,1)
/// and (0.5,0.5), steeper as [amount] grows.
///
/// A smoothstep rather than a gamma, because a gamma moves the midpoint and a
/// look that darkens everything is an exposure change wearing a costume — the
/// same mistake `vd_color.c` avoids by making brightness a gain.
double sCurve(double v, double amount) {
  final smooth = v * v * (3 - 2 * v);
  return v + (smooth - v) * amount;
}

/// Pushes shadows towards one colour and highlights towards another, by how
/// dark or bright the pixel is.
///
/// This is the operation no matrix can do: the direction of the push depends
/// on the value being pushed, and a matrix applies one direction to
/// everything.
Rgb splitTone(Rgb c, Rgb shadow, Rgb highlight, double amount) {
  final l = luma(c);
  // Weighted so the middle of the range keeps its own colour: a split-tone
  // that tinted the mids as well would just be a white balance.
  final shadowWeight = math.pow(1 - l, 2).toDouble();
  final highlightWeight = math.pow(l, 2).toDouble();
  return rgb(
    c.r + (shadow.r * shadowWeight + highlight.r * highlightWeight) * amount,
    c.g + (shadow.g * shadowWeight + highlight.g * highlightWeight) * amount,
    c.b + (shadow.b * shadowWeight + highlight.b * highlightWeight) * amount,
  );
}

/// Moves [c] towards or away from its own grey.
Rgb saturate(Rgb c, double amount) {
  final grey = luma(c);
  return rgb(
    grey + (c.r - grey) * amount,
    grey + (c.g - grey) * amount,
    grey + (c.b - grey) * amount,
  );
}

/// Raises the floor without touching the ceiling: the faded, printed-and-
/// scanned look. Adding a constant is exactly the "lift" `vd_color.c` refuses
/// to make its brightness slider do, which is why it belongs here instead.
Rgb lift(Rgb c, double floor) => rgb(
      floor + c.r * (1 - floor),
      floor + c.g * (1 - floor),
      floor + c.b * (1 - floor),
    );

/// A look, and which pack ships it.
///
/// [pack] empty is the set built into the app — the five free looks every
/// installation has. Anything else is a **content pack**: the cubes are written
/// into `build/packs/<pack>/` beside a manifest, and `app/tool/pack.dart` signs
/// the lot into a `.vdpack`. Same formulae, same file format, same generator;
/// the only difference is which side of `Tier` they land on.
typedef Look = ({
  String name,
  String file,
  String title,
  String pack,
  Rgb Function(Rgb) map,
});

final looks = <Look>[
  // Warm highlights, cool shadows, a gentle curve and a touch off the
  // saturation: the daylight-film look, and the one most footage wants.
  (
    name: 'Warm Film',
    file: 'warm_film.cube',
    title: 'vdodtor Warm Film',
    pack: '',
    map: (c) {
      var out = rgb(sCurve(c.r, 0.22), sCurve(c.g, 0.22), sCurve(c.b, 0.22));
      out = splitTone(out, rgb(-0.02, -0.005, 0.035), rgb(0.045, 0.02, -0.03),
          1.0);
      return saturate(out, 0.94);
    },
  ),
  // Monochrome, with the contrast a black-and-white print gets from its paper.
  // The luma weights are the project's, not the camera's — see vd_color.h.
  (
    name: 'Noir',
    file: 'noir.cube',
    title: 'vdodtor Noir',
    pack: '',
    map: (c) {
      final grey = sCurve(clamp01(luma(c)), 0.55);
      // A hair of blue in the shadows, which is what a silver print does and
      // what keeps a monochrome from reading as a broken colour pipeline.
      return rgb(grey, grey, grey + (1 - grey) * 0.02 * (1 - grey));
    },
  ),
  // The blockbuster split: shadows to teal, skin to orange. The one look that
  // is unmistakably a look.
  (
    name: 'Teal & Orange',
    file: 'teal_orange.cube',
    title: 'vdodtor Teal and Orange',
    pack: '',
    map: (c) {
      var out = rgb(sCurve(c.r, 0.3), sCurve(c.g, 0.3), sCurve(c.b, 0.3));
      out = splitTone(
          out, rgb(-0.06, 0.01, 0.075), rgb(0.07, 0.025, -0.06), 1.0);
      return saturate(out, 1.08);
    },
  ),
  // Lifted blacks, flattened contrast, a cyan cast in the shadows: the
  // washed-out print. Every part of it is something the five sliders
  // deliberately cannot do.
  (
    name: 'Faded',
    file: 'faded.cube',
    title: 'vdodtor Faded',
    pack: '',
    map: (c) {
      var out = saturate(c, 0.82);
      out = lift(out, 0.085);
      // Pulled down at the top as well, so the range closes from both ends —
      // a lift alone reads as fog, not as a faded print.
      out = rgb(out.r * 0.955, out.g * 0.955, out.b * 0.965);
      return splitTone(out, rgb(-0.005, 0.012, 0.03), rgb(0.01, 0.0, -0.012),
          1.0);
    },
  ),
  // Silver retained: the colour laid over its own monochrome, hard contrast,
  // low saturation. A mix of a picture with a function of itself, which is
  // about as far from affine as a look gets.
  (
    name: 'Bleach Bypass',
    file: 'bleach_bypass.cube',
    title: 'vdodtor Bleach Bypass',
    pack: '',
    map: (c) {
      final grey = clamp01(luma(c));
      final hard = sCurve(sCurve(grey, 0.6), 0.6);
      final colour = saturate(c, 0.55);
      return mixRgb(colour, rgb(hard, hard, hard), 0.45);
    },
  ),
  // ---- Cinema, the Pro pack ------------------------------------------------
  //
  // Five that go further than the built-in set: each is a *stronger* claim on
  // the picture rather than a variation on one of the five above, because a
  // paid pack whose looks are near-neighbours of the free ones is a paid pack
  // nobody can tell apart. Generated by the same arithmetic and shipped under
  // the same licence as everything else here — a look sold without an account
  // has to be one we may sell, which the files people share almost never are.

  // Dense blacks, hard shoulder, colour pushed a long way: the saturated
  // transparency stock, and the only look here that touches every channel
  // differently at both ends.
  (
    name: 'Vivid Print',
    file: 'vivid_print.cube',
    title: 'vdodtor Vivid Print',
    pack: 'cinema',
    map: (c) {
      var out = rgb(sCurve(c.r, 0.42), sCurve(c.g, 0.38), sCurve(c.b, 0.46));
      out = saturate(out, 1.3);
      // The blacks close before the whites do, which is what gives a
      // transparency its weight without crushing skin.
      return rgb(
        clamp01(out.r * 1.01 - 0.012),
        clamp01(out.g * 1.005 - 0.014),
        clamp01(out.b - 0.02),
      );
    },
  ),
  // Developed in the wrong chemistry: highlights blown warm, shadows dragged
  // to cyan, contrast up and nothing where it started.
  (
    name: 'Cross Process',
    file: 'cross_process.cube',
    title: 'vdodtor Cross Process',
    pack: 'cinema',
    map: (c) {
      var out = rgb(sCurve(c.r, 0.5), sCurve(c.g, 0.35), sCurve(c.b, 0.15));
      out = splitTone(
          out, rgb(-0.09, 0.015, 0.11), rgb(0.1, 0.055, -0.085), 1.0);
      return saturate(out, 1.22);
    },
  ),
  // The last hour of light: warm highlights, a magenta lift in the shadows,
  // and the saturation an evening actually has rather than the one a
  // temperature slider gives it.
  (
    name: 'Golden Hour',
    file: 'golden_hour.cube',
    title: 'vdodtor Golden Hour',
    pack: 'cinema',
    map: (c) {
      var out = rgb(sCurve(c.r, 0.2), sCurve(c.g, 0.18), sCurve(c.b, 0.12));
      out = lift(out, 0.03);
      out = splitTone(
          out, rgb(0.03, -0.005, 0.025), rgb(0.075, 0.035, -0.045), 1.0);
      return saturate(out, 1.12);
    },
  ),
  // A duotone: the picture's luma mapped onto a ramp from ink to paper. No
  // matrix does this — the output colour does not depend on the input's hue at
  // all — which makes it the clearest example in the set of why looks exist.
  (
    name: 'Cyanotype',
    file: 'cyanotype.cube',
    title: 'vdodtor Cyanotype',
    pack: 'cinema',
    map: (c) {
      final grey = sCurve(clamp01(luma(c)), 0.3);
      const ink = (r: 0.043, g: 0.129, b: 0.267);
      const paper = (r: 0.898, g: 0.949, b: 0.933);
      return rgb(
        ink.r + (paper.r - ink.r) * grey,
        ink.g + (paper.g - ink.g) * grey,
        ink.b + (paper.b - ink.b) * grey,
      );
    },
  ),
  // Crushed blacks, magenta highlights, cyan shadows, saturation well past
  // what daylight has: the city at night, and the one look here that is
  // frankly artificial.
  (
    name: 'Neon Night',
    file: 'neon_night.cube',
    title: 'vdodtor Neon Night',
    pack: 'cinema',
    map: (c) {
      var out = rgb(sCurve(c.r, 0.55), sCurve(c.g, 0.6), sCurve(c.b, 0.5));
      // Down at the bottom rather than lifted: night is where the shadows go.
      out = rgb(
        clamp01(out.r * 1.02 - 0.03),
        clamp01(out.g * 0.98 - 0.035),
        clamp01(out.b * 1.05 - 0.02),
      );
      out = splitTone(
          out, rgb(-0.05, -0.02, 0.09), rgb(0.085, -0.02, 0.075), 1.0);
      return saturate(out, 1.35);
    },
  ),
];

/// What each pack calls itself, and what it costs. Written here beside the
/// looks so that adding one is a single edit in a single file.
const packs = <String, ({String name, String tier, String summary})>{
  'cinema': (
    name: 'Cinema',
    tier: 'pro',
    summary: 'Five looks that commit: print stock, cross process, golden hour, '
        'cyanotype and neon.',
  ),
};

void main(List<String> args) {
  // The built-in five go into the app's assets; a pack's looks go into a
  // staging folder that `app/tool/pack.dart` signs into a `.vdpack`. Two
  // destinations, one generator: see the note on [Look.pack].
  final bundled = Directory(args.isNotEmpty ? args.first : 'app/assets/luts')
    ..createSync(recursive: true);
  final staging = args.length > 1 ? args[1] : 'build/packs';

  Directory directoryFor(String pack) => pack.isEmpty
      ? bundled
      : (Directory('$staging/$pack')..createSync(recursive: true));

  for (final look in looks) {
    final directory = directoryFor(look.pack);
    final buffer = StringBuffer()
      ..writeln('# ${look.name} — generated by tools/make_luts.dart.')
      ..writeln('# Edit the formula there, not this file.')
      ..writeln('TITLE "${look.title}"')
      ..writeln('LUT_3D_SIZE $size')
      ..writeln('DOMAIN_MIN 0.0 0.0 0.0')
      ..writeln('DOMAIN_MAX 1.0 1.0 1.0');

    // Red varies fastest, which is the order the format writes its rows in and
    // the order a 3D texture wants its slices — see vd_lut.h.
    for (var b = 0; b < size; b++) {
      for (var g = 0; g < size; g++) {
        for (var r = 0; r < size; r++) {
          final input = rgb(
            r / (size - 1),
            g / (size - 1),
            b / (size - 1),
          );
          final out = look.map(input);
          buffer.writeln('${_f(out.r)} ${_f(out.g)} ${_f(out.b)}');
        }
      }
    }

    final file = File('${directory.path}/${look.file}');
    file.writeAsStringSync(buffer.toString());
    stdout.writeln('${file.path}  ($size^3, ${file.lengthSync()} bytes)');
  }

  // Each pack gets the manifest `app/tool/pack.dart build` reads, written from
  // the same list that produced its cubes so the two cannot disagree about
  // what is in it.
  packs.forEach((id, pack) {
    final items = looks.where((l) => l.pack == id);
    if (items.isEmpty) return;
    final manifest = StringBuffer()
      ..writeln('id $id')
      ..writeln('name ${pack.name}')
      ..writeln('tier ${pack.tier}')
      ..writeln('summary ${pack.summary}');
    for (final look in items) {
      manifest.writeln('item look|${look.name}|${look.file}');
    }
    final file = File('${directoryFor(id).path}/pack.manifest')
      ..writeAsStringSync(manifest.toString());
    stdout.writeln('${file.path}  (${items.length} looks)');
  });
}

/// Six decimals: past what a 16-bit lattice on the GPU can hold, and short
/// enough that the file stays readable.
String _f(double v) => clamp01(v).toStringAsFixed(6);
