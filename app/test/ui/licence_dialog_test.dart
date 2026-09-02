import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/media/packs.dart';
import 'package:vdodtor/pro/ed25519.dart';
import 'package:vdodtor/pro/licence.dart';
import 'package:vdodtor/pro/licence_store.dart';
import 'package:vdodtor/pro/licensing.dart';
import 'package:vdodtor/pro/tier.dart';
import 'package:vdodtor/ui/licence_dialog.dart';
import 'package:vdodtor/ui/theme.dart';

/// Content goes nowhere: this file is about the sheet, and a widget test has
/// no engine to register a `.cube` with.
final class _Nowhere implements ContentSink {
  const _Nowhere();

  @override
  void look(String name, Uint8List cube) {}

  @override
  void font(Uint8List data) {}
}

/// The disk, held in a variable.
///
/// `testWidgets` runs its body under a fake clock, and a `dart:io` future
/// never completes there — so a sheet whose Activate button writes a file
/// would be a sheet with no widget test. What is being checked here is what
/// the sheet does and says, and where the bytes end up is
/// `test/pro/licensing_test.dart`'s subject.
final class _MemoryStore implements LicenceStore {
  String? key;

  @override
  Future<String?> read() async => key;

  @override
  Future<void> write(String value) async => key = value;

  @override
  Future<void> remove() async => key = null;
}

final _seed = List<int>.generate(32, (i) => (i * 13 + 1) & 0xff);
final _verifier = LicenceVerifier(
  publicKey: Ed25519.publicKeyOf(_seed)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(),
);

String mint({String id = 'LS-1042', String name = 'Ada Lovelace', DateTime? expires}) =>
    signLicence(
      seed: _seed,
      payload: licencePayload(
        id: id,
        tier: Tier.pro,
        name: name,
        issued: DateTime.utc(2026, 1, 1),
        expires: expires,
      ),
    );

void main() {
  const system = MethodChannel('vdodtor/system');
  const access = MethodChannel('vdodtor/media_access');
  final opened = <String>[];
  final panels = <MethodCall>[];
  late _MemoryStore store;
  late Directory packs;
  final now = DateTime.utc(2026, 9, 2);

  // The catalogue is loaded out here rather than inside a test body: it reads
  // the bundle and the Packs folder, and `testWidgets` runs its body under a
  // fake clock where a `dart:io` future never completes. What installing
  // *does* is `test/media/packs_test.dart`'s subject; this file is about what
  // the sheet shows.
  setUp(() async {
    opened.clear();
    panels.clear();
    store = _MemoryStore();
    packs = await Directory.systemTemp.createTemp('vdodtor-sheet-packs');
    await ContentPacks.load(installed: packs, sink: const _Nowhere());

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(system, (call) async {
        opened.add((call.arguments as Map)['url'] as String);
        return true;
      })
      ..setMockMethodCallHandler(access, (call) async {
        panels.add(call);
        // Cancelled, which is the one answer that touches no disk.
        return <Object?>[];
      });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(system, null)
      ..setMockMethodCallHandler(access, null);
    ContentPacks.reset();
    if (packs.existsSync()) await packs.delete(recursive: true);
  });

  Future<Licensing> openSheet(WidgetTester tester) async {
    final licensing = Licensing(
      store: store,
      verifier: _verifier,
      clock: () => now,
    );
    addTearDown(licensing.dispose);
    await licensing.load();

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () =>
                  showLicenceDialog(context, licensing: licensing),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return licensing;
  }

  Future<void> type(WidgetTester tester, String key) async {
    await tester.enterText(find.byType(TextField), key);
    await tester.pump();
  }

  group('before it is bought', () {
    // The free tier is described first and in full. This assertion is the
    // whole positioning of the product, and it is meant to be annoying to
    // change.
    testWidgets('says what is free before it says what costs money',
        (tester) async {
      await openSheet(tester);

      expect(
        find.textContaining('no watermark, no account and no ads, ever'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Pro adds 4K and larger exports'),
        findsOneWidget,
      );
    });

    testWidgets('sends Buy to an address we own, not to the shop',
        (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Buy vdodtor Pro'));
      await tester.pumpAndSettle();

      expect(opened, ['https://vdodtor.app/pro']);
    });

    testWidgets('sends Find my key somewhere a key can be found',
        (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Find my key'));
      await tester.pumpAndSettle();

      expect(opened, ['https://vdodtor.app/licence']);
    });

    testWidgets('a rejected key says which way it was wrong', (tester) async {
      final licensing = await openSheet(tester);
      await type(tester, 'nonsense');
      await tester.tap(find.text('Activate'));
      await tester.pumpAndSettle();

      expect(find.text(LicenceProblem.unrecognised.message), findsOneWidget);
      expect(licensing.isPro, isFalse);
    });

    testWidgets('the message goes away when the text does', (tester) async {
      await openSheet(tester);
      await type(tester, 'nonsense');
      await tester.tap(find.text('Activate'));
      await tester.pumpAndSettle();
      expect(find.text(LicenceProblem.unrecognised.message), findsOneWidget);

      await type(tester, 'VDO1');
      expect(find.text(LicenceProblem.unrecognised.message), findsNothing);
    });

    testWidgets('a good key turns the sheet into a receipt', (tester) async {
      final licensing = await openSheet(tester);
      await type(tester, mint());
      await tester.tap(find.text('Activate'));
      await tester.pumpAndSettle();

      expect(licensing.isPro, isTrue);
      expect(
        find.text('Pro is active on this Mac, licensed to Ada Lovelace.'),
        findsOneWidget,
      );
      expect(find.text('LS-1042'), findsOneWidget);
      expect(find.text('Lifetime'), findsOneWidget);
      expect(find.text('Buy vdodtor Pro'), findsNothing);
    });

    testWidgets('a subscription says when it renews rather than "lifetime"',
        (tester) async {
      await openSheet(tester);
      await type(tester, mint(expires: DateTime.utc(2027, 3, 4)));
      await tester.tap(find.text('Activate'));
      await tester.pumpAndSettle();

      expect(find.text('4 March 2027'), findsOneWidget);
      expect(find.text('Lifetime'), findsNothing);
    });

    // "You are on the free tier" answers nothing; the date does.
    testWidgets('a subscription that ran out says so, with the date',
        (tester) async {
      store.key = mint(expires: DateTime.utc(2026, 2, 3));

      await openSheet(tester);

      expect(
        find.textContaining('ended on 3 February 2026'),
        findsOneWidget,
      );
      expect(find.text('Buy vdodtor Pro'), findsOneWidget);
    });
  });

  group('once it is bought', () {
    Future<Licensing> licensed(WidgetTester tester) {
      store.key = mint();
      return openSheet(tester);
    }

    testWidgets('removing it frees the Mac and offers the sheet again',
        (tester) async {
      final licensing = await licensed(tester);
      expect(licensing.isPro, isTrue);

      await tester.tap(find.text('Remove from this Mac'));
      await tester.pumpAndSettle();

      expect(licensing.isPro, isFalse);
      expect(store.key, isNull);
      expect(find.text('Buy vdodtor Pro'), findsOneWidget);
    });

    // A deactivation that read like a cancellation would stop people doing
    // the thing that is actually safe.
    testWidgets('says removing it does not use it up', (tester) async {
      await licensed(tester);
      expect(
        find.textContaining('does not use it up'),
        findsOneWidget,
      );
    });
  });

  group('content packs', () {
    testWidgets('are listed, with the one that costs money marked',
        (tester) async {
      await openSheet(tester);

      expect(find.text('Cinema'), findsOneWidget);
      expect(find.textContaining('print stock, cross process'), findsOneWidget);
      expect(find.byType(ProBadge), findsOneWidget);
    });

    // The pack is on the machine either way; what is being sold is the right
    // to use it. Hiding it until after the purchase would mean asking somebody
    // to buy a list of names.
    testWidgets('lose the badge once Pro is on, and stay listed',
        (tester) async {
      store.key = mint();
      await openSheet(tester);

      expect(find.text('Cinema'), findsOneWidget);
      expect(find.byType(ProBadge), findsNothing);
    });

    testWidgets('can be added, through the panel', (tester) async {
      await openSheet(tester);
      await tester.ensureVisible(find.text('Install a pack…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install a pack…'));
      await tester.pumpAndSettle();

      expect(panels, hasLength(1));
      expect(panels.single.method, 'pickFiles');
      expect((panels.single.arguments as Map)['extensions'], ['vdpack']);
    });
  });

  // The build that trusts a key anybody can sign for has to say so, and stop
  // saying so the moment the release key replaces it.
  testWidgets('owns up to a development signing key', (tester) async {
    await openSheet(tester);
    expect(
      find.textContaining('trusts the development signing key'),
      isDevelopmentSigningKey ? findsOneWidget : findsNothing,
    );
  });
}
