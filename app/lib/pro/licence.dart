/// What a licence is: a statement about a purchase, and a signature over it.
///
/// **The whole design in one line: a licence key is a signed sentence the app
/// can read on a plane.** Nothing here calls anything, waits for anything, or
/// knows what a server is. That is not an optimisation — it is the product.
/// The brief sells an editor with no account and no ads, and an editor that
/// had to ask permission before letting somebody export would have an
/// account, whatever the sign-up screen said.
///
/// The consequence to hold on to is that **a licence cannot be revoked**.
/// Whatever is signed is true forever, on every machine, with no way to take
/// it back. So a licence says as little as possible: who bought it, what they
/// bought, and — for a subscription — until when. There is no device count in
/// it, because a number nobody can check is a number that only inconveniences
/// the people who paid.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'ed25519.dart';
import 'tier.dart';

/// The product a licence has to name. A key for something else we sell later
/// must not open this, and the check costs one string comparison.
const String vdodtorProduct = 'vdodtor';

/// The public half of the key licences are signed with.
///
/// **This is the development key, and its private half is in this repository**
/// at `app/tool/licence_dev_key.txt`. That is correct for as long as nothing
/// is being sold: it lets the whole flow be exercised, and it lets a test mint
/// a licence without a secret in the source tree. It is also the one line that
/// must change before a build is signed and shipped — generate a keypair with
/// `dart run tool/licence.dart keygen`, paste the public half here, and keep
/// the private half in the fulfilment webhook's secret store and nowhere else.
///
/// Forgetting would give Pro away to anybody who reads GitHub, so the licence
/// sheet says out loud when [isDevelopmentSigningKey] is true. A build that
/// hands out what it is meant to sell should be embarrassing rather than
/// quiet.
const String vdodtorSigningKey = _developmentSigningKey;

/// The key whose private half this repository carries. Named separately from
/// [vdodtorSigningKey] so that replacing the one above is a one-line change
/// that this comparison then reports as done.
const String _developmentSigningKey =
    '5f3cf3677bf66619b0a886221a2042ec50aab4e25b105541b17a9d9961a4957c';

/// True while [vdodtorSigningKey] is still the one anybody can sign for.
bool get isDevelopmentSigningKey =>
    vdodtorSigningKey == _developmentSigningKey;

/// How long a lapsed subscription keeps working.
///
/// A renewal receipt that arrives on Tuesday should not stop somebody
/// exporting on Monday night. Two weeks is long enough to cover a card that
/// needed re-authorising and an email that went to spam, and short enough that
/// it is a grace period rather than a fortnight of free Pro worth gaming. It
/// applies to nothing else: a lifetime licence has no expiry to be graceful
/// about.
const Duration licenceGrace = Duration(days: 14);

/// Why a pasted key is not in force.
enum LicenceProblem {
  /// Nothing was pasted, or only whitespace was.
  empty('Paste the licence key from your receipt.'),

  /// Not a vdodtor licence key at all — the wrong prefix, the wrong number of
  /// parts, or characters that are not in the alphabet.
  unrecognised('That does not look like a vdodtor licence key. Copy the '
      'whole line from your receipt, including the VDO1 at the start.'),

  /// The bytes are a licence, and the signature over them is not ours.
  /// Either it was edited — a date pushed out, a name changed — or it was
  /// invented.
  forged('That licence key is not valid. If you typed it out, paste it '
      'instead; if you copied it, the receipt it came from is not one of '
      'ours.'),

  /// Signed by us, for something else.
  otherProduct('That licence is for another product.'),

  /// Signed by us and missing something a licence needs, which means it was
  /// written by a version of the fulfilment tool this build predates.
  incomplete('That licence needs a newer version of vdodtor to read.'),

  /// Signed by us, ours, and past its date.
  expired('That licence has expired. Renewing it will send a new key.');

  const LicenceProblem(this.message);

  /// What the sheet says. Written out here rather than at the point of
  /// display because there is one place a licence can be rejected and it
  /// should give one answer wherever it is shown.
  final String message;
}

/// A purchase, as the app understands it.
@immutable
final class Licence {
  const Licence({
    required this.key,
    required this.id,
    required this.product,
    required this.tier,
    this.name = '',
    this.issued,
    this.expires,
  });

  /// The key exactly as it was pasted. Kept because it is what gets written
  /// to disk: re-encoding a licence to store it would mean a licence that
  /// round-tripped badly stopped verifying, and the file on disk should be
  /// the thing the user was emailed.
  final String key;

  /// The order this came from. Shown so that a support email can say which
  /// purchase it is about without asking for the whole key.
  final String id;

  final String product;
  final Tier tier;

  /// Who it was bought by, or empty. Shown, never checked — a licence is not
  /// a login.
  final String name;

  final DateTime? issued;

  /// When a subscription runs out. Null is a lifetime licence, which is most
  /// of them and all of the ones sold so far.
  final DateTime? expires;

  bool get isPerpetual => expires == null;

  /// The last moment this licence works, grace included.
  DateTime? get lapsesAfter => expires?.add(licenceGrace);

  bool isInForceAt(DateTime now) =>
      expires == null || now.isBefore(expires!.add(licenceGrace));

  @override
  String toString() => 'Licence($id, ${tier.label}'
      '${expires == null ? ', lifetime' : ', until $expires'})';
}

/// The result of looking at a pasted key.
///
/// Both halves can be set at once, and that is the useful case: an expired
/// licence is a real purchase with a real name on it, and the sheet should say
/// *whose subscription lapsed and when* rather than "invalid". Only [problem]
/// being null means the licence is in force.
@immutable
final class LicenceCheck {
  const LicenceCheck({this.licence, this.problem});

  const LicenceCheck.rejected(LicenceProblem problem)
      : this(problem: problem);

  /// The purchase, whenever the signature was ours and the payload parsed —
  /// even when [problem] says it is out of date.
  final Licence? licence;

  final LicenceProblem? problem;

  bool get isInForce => licence != null && problem == null;
}

/// Reads licence keys, and is the only thing that decides whether one counts.
///
/// The key it trusts is a constructor argument rather than a constant read
/// inside, so a test can mint its own licences with its own keypair. The
/// shipping app uses [LicenceVerifier.release] and nothing else.
@immutable
final class LicenceVerifier {
  const LicenceVerifier({
    this.publicKey = vdodtorSigningKey,
    this.product = vdodtorProduct,
  });

  /// What the app runs with.
  static const LicenceVerifier release = LicenceVerifier();

  /// Hex, 32 bytes.
  final String publicKey;

  final String product;

  /// Every key starts with this. A version in the envelope rather than in the
  /// payload, so that a future format can be recognised as one rather than
  /// read as damage.
  static const String prefix = 'VDO1';

  LicenceCheck check(String pasted, {DateTime? now}) {
    final key = pasted.trim();
    if (key.isEmpty) return const LicenceCheck.rejected(LicenceProblem.empty);

    final parts = key.split('.');
    if (parts.length != 3 || parts[0] != prefix) {
      return const LicenceCheck.rejected(LicenceProblem.unrecognised);
    }

    final Uint8List payload;
    final Uint8List signature;
    try {
      payload = _decode(parts[1]);
      signature = _decode(parts[2]);
    } on FormatException {
      return const LicenceCheck.rejected(LicenceProblem.unrecognised);
    }
    if (signature.length != Ed25519.signatureBytes) {
      return const LicenceCheck.rejected(LicenceProblem.unrecognised);
    }

    final trusted = Ed25519.keyFromHex(publicKey);
    if (trusted == null) {
      return const LicenceCheck.rejected(LicenceProblem.forged);
    }

    // **The signature covers the bytes that arrived, and parsing happens
    // afterwards.** Not a detail: verifying a re-encoding of the payload
    // would mean a licence stopped working the day the writer changed how it
    // spaced a field, and it would mean a field this build does not
    // understand could change what was checked. Bytes in, bytes verified,
    // then read.
    if (!Ed25519.verify(
      publicKey: trusted,
      message: payload,
      signature: signature,
    )) {
      return const LicenceCheck.rejected(LicenceProblem.forged);
    }

    final fields = _fields(utf8.decode(payload, allowMalformed: true));
    if (fields['product'] != product) {
      return const LicenceCheck.rejected(LicenceProblem.otherProduct);
    }

    final id = fields['id'];
    final tier = _tierNamed(fields['tier']);
    if (id == null || id.isEmpty || tier == null) {
      return const LicenceCheck.rejected(LicenceProblem.incomplete);
    }

    final expires = _date(fields['expires']);
    if (fields['expires'] != null && expires == null) {
      return const LicenceCheck.rejected(LicenceProblem.incomplete);
    }

    final licence = Licence(
      key: key,
      id: id,
      product: fields['product']!,
      tier: tier,
      name: fields['name'] ?? '',
      issued: _date(fields['issued']),
      expires: expires,
    );

    return LicenceCheck(
      licence: licence,
      problem: licence.isInForceAt(now ?? DateTime.now())
          ? null
          : LicenceProblem.expired,
    );
  }
}

/// The lines a licence is made of, in the order the fulfilment tool writes
/// them.
///
/// A flat `name value` list rather than JSON, because the thing being signed
/// is bytes and JSON invites a re-encode — two writers that disagree about
/// key order or whitespace produce two payloads for one licence, and only one
/// of them verifies. This has one spelling and it is the one that was signed.
String licencePayload({
  required String id,
  required Tier tier,
  String name = '',
  DateTime? issued,
  DateTime? expires,
  String product = vdodtorProduct,
}) {
  final lines = <String>[
    'product ${_field(product)}',
    'id ${_field(id)}',
    'tier ${tier.name}',
    if (name.isNotEmpty) 'name ${_field(name)}',
    'issued ${_day(issued ?? DateTime.now().toUtc())}',
    if (expires != null) 'expires ${_day(expires)}',
  ];
  return lines.join('\n');
}

/// One line's worth of a value.
///
/// A field is terminated by a newline, so a buyer called `Bob\ntier free`
/// would be a buyer who wrote a line into their own licence. Nothing in the
/// reader can defend against that — by then it is signed, and signed by us —
/// so it is prevented here, at the only place a payload is ever written.
/// Order names and buyer names come from a payment provider's webhook, which
/// is somebody else's idea of what may be in a string.
String _field(String value) =>
    value.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();

/// Signs a payload into a key. In the app so that a test can mint licences;
/// called for real only by `app/tool/licence.dart`, which is where the
/// private key is handed in from outside this repository.
String signLicence({required List<int> seed, required String payload}) {
  final bytes = utf8.encode(payload);
  final signature = Ed25519.sign(seed: seed, message: bytes);
  return '${LicenceVerifier.prefix}.${_encode(bytes)}.${_encode(signature)}';
}

String _day(DateTime date) {
  final utc = date.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

DateTime? _date(String? text) {
  if (text == null) return null;
  final parts = text.split('-');
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  return DateTime.utc(year, month, day);
}

Tier? _tierNamed(String? name) {
  for (final tier in Tier.values) {
    if (tier.name == name) return tier;
  }
  return null;
}

Map<String, String> _fields(String payload) {
  final fields = <String, String>{};
  for (final line in payload.split('\n')) {
    final space = line.indexOf(' ');
    if (space <= 0) continue;
    // First wins, so a second `tier` line appended to a payload cannot
    // overwrite the one that was signed into it.
    fields.putIfAbsent(line.substring(0, space), () => line.substring(space + 1));
  }
  return fields;
}

/// Base64url without padding: a licence key goes in an email and through a
/// text field, and `=` is the character most likely to be eaten on the way.
String _encode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _decode(String text) {
  final padded = text.padRight((text.length + 3) & ~3, '=');
  return base64Url.decode(padded);
}
