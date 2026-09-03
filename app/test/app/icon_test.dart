import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../../tools/make_icon.dart';

/// The icon vdodtor ships, checked against the geometry it is drawn from.
///
/// `tools/make_icon.dart` is a generator, and every generator in this
/// repository has the same failure waiting for it: somebody changes the source
/// — a lane colour, the squircle's exponent, the size list Apple asks for — and
/// nobody re-runs it, so the thing that ships is a picture of a decision that
/// is no longer the decision. `about_test.dart` catches that for the licence
/// notice by comparing the shipped file to the vendored library; this catches
/// it for the icon by drawing it again and comparing.
///
/// Re-run the generator and this goes green:
///
///   dart run tools/make_icon.dart      # from the repository root
///
/// It compares **pixels rather than bytes**, which is the compositor's goldens'
/// rule and is here for a plainer reason: what ships is the picture, and the
/// bytes around it are whatever deflate happened to produce for the zlib built
/// into whichever Dart SDK ran the generator. A test that went red on an SDK
/// upgrade while the icon was identical would be a test people learn to
/// re-approve without looking, which is the opposite of what a golden is for.
void main() {
  // Tests run with the app package as the working directory. The catalogue is
  // inside it; the generator that writes it is a level up, beside it.
  final catalogue =
      Directory('macos/Runner/Assets.xcassets/AppIcon.appiconset');

  test('the catalogue holds exactly the files the generator writes', () {
    expect(catalogue.existsSync(), isTrue);

    final present = catalogue
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.png'))
        .toSet();
    expect(
      present,
      iconSizes.map(iconFileName).toSet(),
      reason: 'a file here that the generator does not write is one nothing '
          'can keep up to date — run `dart run tools/make_icon.dart`',
    );

    // And Contents.json has to name them, or actool ships the slot empty and
    // the Dock falls back to a blank page with no error anywhere.
    final contents = jsonDecode(
      File('${catalogue.path}/Contents.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final named = (contents['images'] as List<dynamic>)
        .map((i) => (i as Map<String, dynamic>)['filename'] as String)
        .toSet();
    expect(named, present);
  });

  for (final size in iconSizes) {
    test('${iconFileName(size)} is what the generator draws', () {
      final file = File('${catalogue.path}/${iconFileName(size)}');
      expect(file.existsSync(), isTrue,
          reason: 'run `dart run tools/make_icon.dart`');

      final shipped = _decodePng(file.readAsBytesSync());
      expect(shipped.width, size);
      expect(shipped.height, size);

      final drawn = renderIcon(size);
      expect(drawn.length, shipped.pixels.length);

      // Report the first disagreement rather than dumping a megabyte of bytes
      // into the failure, which is what `expect(list, list)` would do.
      for (var i = 0; i < drawn.length; i++) {
        if (drawn[i] != shipped.pixels[i]) {
          final p = i ~/ 4;
          fail('${iconFileName(size)} differs from the geometry it is drawn '
              'from, first at (${p % size}, ${p ~/ size}) channel ${i % 4}: '
              'shipped ${shipped.pixels[i]}, drawn ${drawn[i]} — run '
              '`dart run tools/make_icon.dart`');
        }
      }
    });
  }

  test('the mark is drawn in the palette the timeline is drawn in', () {
    // The pixel comparison above would catch a recolour, but it would report
    // it as "byte 41372 differs", which says nothing about what broke. This
    // says it: the one loud colour in the product is on the icon, and it is
    // the same loud colour.
    final icon = _decodePng(
      File('${catalogue.path}/${iconFileName(1024)}').readAsBytesSync(),
    );

    var playhead = 0;
    for (var p = 0; p < icon.width * icon.height; p++) {
      if (icon.pixels[p * 4] == 0xFF &&
          icon.pixels[p * 4 + 1] == 0x5C &&
          icon.pixels[p * 4 + 2] == 0x5C &&
          icon.pixels[p * 4 + 3] == 0xFF) {
        playhead++;
      }
    }
    expect(playhead, greaterThan(1000),
        reason: 'VdColors.playhead is 0xFF5C5C and the icon should be wearing '
            'it — the icon and the editor are one product');
  });
}

class _Image {
  const _Image(this.width, this.height, this.pixels);
  final int width, height;
  final Uint8List pixels;
}

/// Enough of a PNG reader to read one back: 8-bit RGBA, not interlaced.
///
/// All five filters, although the generator only writes filter 0, so that a
/// file dropped in here by some other tool fails on the *pixels* — which is the
/// interesting sentence — rather than on an unsupported filter byte.
_Image _decodePng(Uint8List bytes) {
  expect(bytes.sublist(0, 8),
      <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  var width = 0, height = 0;
  final idat = BytesBuilder();
  var i = 8;
  while (i < bytes.length) {
    final length = bytes.buffer.asByteData().getUint32(i);
    final type = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
    final body = bytes.sublist(i + 8, i + 8 + length);
    if (type == 'IHDR') {
      final header = body.buffer.asByteData(body.offsetInBytes);
      width = header.getUint32(0);
      height = header.getUint32(4);
      expect(body[8], 8, reason: 'bit depth');
      expect(body[9], 6, reason: 'colour type: truecolour with alpha');
      expect(body[12], 0, reason: 'interlacing');
    } else if (type == 'IDAT') {
      idat.add(body);
    }
    i += 12 + length;
  }

  final raw = Uint8List.fromList(zlib.decode(idat.takeBytes()));
  final stride = width * 4;
  final out = Uint8List(height * stride);
  final previous = Uint8List(stride);
  var read = 0;
  for (var y = 0; y < height; y++) {
    final filter = raw[read++];
    final line = Uint8List.fromList(raw.sublist(read, read + stride));
    read += stride;
    for (var x = 0; x < stride; x++) {
      final a = x >= 4 ? line[x - 4] : 0;
      final b = previous[x];
      final c = x >= 4 ? previous[x - 4] : 0;
      line[x] = switch (filter) {
        0 => line[x],
        1 => line[x] + a,
        2 => line[x] + b,
        3 => line[x] + ((a + b) >> 1),
        4 => line[x] + _paeth(a, b, c),
        _ => fail('unknown PNG filter $filter'),
      };
    }
    out.setRange(y * stride, (y + 1) * stride, line);
    previous.setRange(0, stride, line);
  }
  return _Image(width, height, out);
}

int _paeth(int a, int b, int c) {
  final p = a + b - c;
  final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
  if (pa <= pb && pa <= pc) return a;
  return pb <= pc ? b : c;
}
