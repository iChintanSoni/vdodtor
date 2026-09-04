import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/app/about.dart';
import 'package:vdodtor/pro/checkout.dart';

import '../../../tools/make_icon.dart';

/// The addresses the app opens, checked against the site that has to answer
/// them.
///
/// **Why this is a test and not a checklist.** vdodtor has no updater — that is
/// a deliberate feature, not a gap — so a build from 2026 has to keep working in
/// 2031 with the URLs that were compiled into it. There is no way to fix a link
/// after the fact: no remote config, no phone-home, not even a socket to open.
/// A page renamed on the site is therefore a dead button in every copy ever
/// installed, permanently. `Checkout.buy` is the worst of them — it is the
/// purchase path, and it fails at exactly the moment somebody had decided to
/// pay.
///
/// So the app and the site are two sides of one boundary that has to agree, and
/// this is the `vd_time.c`/`time.dart` arrangement pointed at hyperlinks: both
/// sides in one assertion, so drift is red rather than discovered by a stranger.
///
/// It reads `lib/` for the addresses rather than only the named constants,
/// which is `about_test.dart`'s trick for the network-API scan: a link added in
/// a file nobody thought to list still has to have somewhere to land.
void main() {
  // Tests run with the app package as the working directory; the site is a
  // level up, beside it.
  final site = Directory('../site');
  const host = 'vdodtor.app';

  /// Every `https://vdodtor.app/...` written down anywhere in the app.
  Set<String> addressesInLib() {
    final found = <String>{};
    final pattern = RegExp('https://$host(/[a-z0-9/-]*)');
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      for (final match in pattern.allMatches(entity.readAsStringSync())) {
        found.add(match.group(1)!);
      }
    }
    return found;
  }

  /// Where a path served by this site lives on disk. `/download` is
  /// `download/index.html`, so that every host serves it without a rewrite
  /// rule and the app's URL needs no trailing slash.
  File pageFor(String path) =>
      File('${site.path}${path == '/' ? '' : path}/index.html');

  test('the site exists and is served from the root', () {
    expect(site.existsSync(), isTrue);
    expect(pageFor('/').existsSync(), isTrue);
  });

  test('the site is published at the address the app opens', () {
    // The one file under site/ that is not part of the site: the host reads
    // the domain out of it, and the app reads the same domain out of a string
    // compiled into a build that can never be told otherwise. Publishing under
    // any other name is the same failure as renaming a page — every button in
    // every copy already installed, dead — so the two are asserted together
    // rather than kept in step by memory.
    //
    // It also has to be *this* name and not a subpath: every link, the
    // stylesheet and both icons are absolute, so the site works at the root of
    // a domain and nowhere else. A project page under /vdodtor/ would serve
    // eight pages that all look unstyled and link to nothing.
    final cname = File('${site.path}/CNAME');
    expect(cname.existsSync(), isTrue,
        reason: 'site/CNAME is what tells the host which domain to serve, and '
            'without it a deploy lands somewhere the app never points at');
    expect(cname.readAsStringSync().trim(), host);
  });

  test('every address the app opens is a page the site serves', () {
    final addresses = addressesInLib();
    expect(addresses, isNotEmpty, reason: 'the scan found nothing, so it is '
        'no longer scanning what it thinks it is');

    for (final path in addresses) {
      final page = File(
        '${site.path}$path${path.endsWith('.md') || path.endsWith('.txt') ? '' : '/index.html'}',
      );
      expect(page.existsSync(), isTrue,
          reason: 'the app opens https://$host$path and the site has no '
              '${page.path}. There is no updater, so a copy of vdodtor that '
              'is already installed can never be pointed somewhere else.');
    }
  });

  test('the addresses the app names are the ones that were checked', () {
    // The scan above is the safety net; these are the five that exist on
    // purpose. Naming them means deleting a page *and* its only caller cannot
    // quietly pass, and it is where the host itself is asserted — an address
    // we own is the whole reason Checkout.buy is a redirect rather than the
    // payment provider's URL.
    final named = <Uri>[
      About.source,
      About.download,
      About.bugs,
      Checkout.buy,
      Checkout.findKey,
    ];
    final scanned = addressesInLib();
    for (final uri in named) {
      expect(uri.scheme, 'https');
      expect(uri.host, host);
      expect(scanned, contains(uri.path));
      expect(pageFor(uri.path).existsSync(), isTrue);
    }
    expect(named.map((u) => u.path).toSet(),
        {'/source', '/download', '/bugs', '/pro', '/licence'});
  });

  test('nothing on the site links to a page the site does not have', () {
    final links = RegExp('href="(/[^"#?]*)"');
    for (final page in _pages(site)) {
      for (final match in links.allMatches(page.readAsStringSync())) {
        final target = match.group(1)!;
        final onDisk = target.contains('.')
            ? File('${site.path}$target')
            : pageFor(target);
        expect(onDisk.existsSync(), isTrue,
            reason: '${page.path} links to $target and there is no '
                '${onDisk.path}');
      }
    }
  });

  test('the download page names the version that would be built', () {
    // The version is already written twice — pubspec.yaml and
    // AppInfo.xcconfig, which about_test.dart makes agree. This is the third,
    // and it is the copy a *stranger* reads, so a download page offering a
    // version that was never released is worse than the other two disagreeing.
    final version = RegExp(r'^version:\s*([^+\s]+)', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync())!
        .group(1)!;
    expect(pageFor('/download').readAsStringSync(), contains(version),
        reason: 'app/pubspec.yaml says $version and the download page does '
            'not offer it');
  });

  test('the source page serves the notices that actually shipped', () {
    // Not a retelling of them: the notice is a licence obligation, generated
    // from the libraries vendored, and a second copy written in the site's own
    // words is a second thing that can be wrong about the LGPL. These are the
    // bytes. `tools/make_notices.dart` writes both places; if this is red, it
    // was not re-run.
    for (final name in const ['THIRD_PARTY_NOTICES.md', 'LGPL-2.1.txt']) {
      final shipped = File('assets/notices/$name');
      final served = File('${site.path}/source/$name');
      expect(served.existsSync(), isTrue);
      expect(served.readAsBytesSync(), shipped.readAsBytesSync(),
          reason: '$name differs between the app bundle and the site — '
              'run `dart run tools/make_notices.dart`');
    }
  });

  test('the site wears the icon the app wears', () {
    // One mark, from one generator. A visitor who sees one icon on the
    // download page and another in their Dock has been told, quietly, that
    // these are two products.
    siteIcons.forEach((name, size) {
      final file = File('${site.path}/$name');
      expect(file.existsSync(), isTrue,
          reason: 'run `dart run tools/make_icon.dart`');
      expect(file.readAsBytesSync(), encodePng(size, renderIcon(size)),
          reason: '$name is not what tools/make_icon.dart draws at $size px');
    });
  });

  test('every page can be found and shared', () {
    // Cheap hygiene with an expensive failure: a page with no title is a
    // browser tab reading "vdodtor.app/pro", and one with no description is a
    // search result that quotes the navigation bar. This is the site an
    // unknown editor is judged by before anything is downloaded.
    for (final page in _pages(site)) {
      final html = page.readAsStringSync();
      expect(RegExp('<title>[^<]{8,}</title>').hasMatch(html), isTrue,
          reason: '${page.path} has no useful <title>');
      expect(html, contains('name="description"'),
          reason: '${page.path} has no meta description');
      expect(html, contains('<html lang='),
          reason: '${page.path} does not say what language it is in');
      expect(html, contains('name="viewport"'),
          reason: '${page.path} will not lay out on a phone');
    }
  });
}

List<File> _pages(Directory site) => site
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.html'))
    .toList();
