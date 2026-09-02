import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vdodtor/pro/ed25519.dart';
import 'package:vdodtor/pro/licence.dart';
import 'package:vdodtor/pro/licence_store.dart';
import 'package:vdodtor/pro/licensing.dart';
import 'package:vdodtor/pro/tier.dart';
import 'package:vdodtor/ui/licence_dialog.dart';

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
  final opened = <String>[];
  late _MemoryStore store;
  final now = DateTime.utc(2026, 9, 2);

  setUp(() {
    opened.clear();
    store = _MemoryStore();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(system, (call) async {
      opened.add((call.arguments as Map)['url'] as String);
      return true;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(system, null);
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
