/// The one thing the editor asks the rest of the machine to do: open a page
/// in the user's browser.
library;

import 'package:flutter/services.dart';

/// Opens web addresses.
///
/// Static for [MediaAccess]'s reason: there is one machine, and an instance
/// per caller would be an instance per nothing. Everything it is given is a
/// constant this app wrote down — the checkout, the page that finds a lost
/// licence key — and the platform side refuses anything that is not `http` or
/// `https`, so there is no route from a document to Launch Services.
abstract final class SystemLinks {
  static const MethodChannel _channel = MethodChannel('vdodtor/system');

  /// Opens [url], returning false if it could not be opened — off macOS,
  /// under a widget test with no platform behind the channel, or because the
  /// machine has nothing registered for it.
  ///
  /// False rather than a throw because every caller is a button, and a button
  /// that could crash the app by being pressed is worse than one that does
  /// nothing visible. The one caller that cares says so on screen.
  static Future<bool> open(Uri url) async {
    try {
      final opened =
          await _channel.invokeMethod<bool>('openUrl', {'url': url.toString()});
      return opened ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
