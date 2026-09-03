/// Where somebody goes to buy Pro, and to find a key they have lost.
///
/// **Both are addresses we own, and neither is the payment provider's.**
/// PLAN.md offers a choice between Paddle and Lemon Squeezy, and this is how
/// that choice stops being one the app has an opinion about: the button opens
/// `vdodtor.app/pro`, that page redirects to whichever hosted checkout we are
/// using this year, and switching providers — or running both, or moving to a
/// storefront that does not exist yet — never needs a new build. A build from
/// 2026 has to keep working in 2031, and a checkout URL baked into it is the
/// part most likely to have been retired by then.
///
/// Both providers are merchants of record, which is the reason to use either:
/// they carry the VAT and sales-tax registration in every country an editor
/// sold direct will land in, and that is not work a product this size can do
/// itself.
///
/// The domain is settled (OQ-4), and the pages behind these two are in `site/`
/// in this repository — not because a marketing site belongs beside an engine,
/// but because there is **no updater**: a build from 2026 opens the URL that
/// was compiled into it and can never be told otherwise. So the app and the
/// site are two sides of one boundary that has to agree, and
/// `test/app/site_test.dart` is what makes them, the way `about_test.dart`
/// makes the licence notice agree with the libraries that shipped.
library;

abstract final class Checkout {
  /// The buy page. Opened by the button in the licence sheet and by the gate
  /// in the export sheet.
  static final Uri buy = Uri.parse('https://vdodtor.app/pro');

  /// Where to look a key up again by the email it was bought with. This is
  /// the whole of "restore purchases" for a product with no account: there is
  /// nothing to sign into, so the receipt is the thing to find.
  static final Uri findKey = Uri.parse('https://vdodtor.app/licence');
}
