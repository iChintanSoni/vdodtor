/// Colour looks, handed to the engine so it can grade with them.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

/// The engine's look catalogue.
///
/// The same arrangement `TextFonts` has, for the same two reasons. Looks are
/// registered by *bytes* because the ones the app ships live inside a signed
/// bundle where the only address anybody has for them is an asset key; and
/// they are referred to by *name* because a document that names a look reads
/// like the edit that made it rather than like one machine's filesystem.
///
/// Registration is per process. The list starts empty and stays empty until
/// somebody fills it, which the app does once at startup — from its bundled
/// `.cube` files and from whatever the user has added to their own library.
///
/// A clip naming a look this installation does not have draws ungraded, which
/// is exactly what a caption in a missing face already does.
abstract final class Looks {
  /// Registers one `.cube` under [name].
  ///
  /// Registering a name that is already there does nothing and is not an
  /// error — it is what happens after a hot restart — so this is safe to call
  /// again. Throws [EngineException] if the bytes are not a readable `.cube`.
  static void register(String name, Uint8List cube) {
    final key = name.toNativeUtf8();
    final buffer = malloc<Uint8>(cube.length);
    try {
      buffer.asTypedList(cube.length).setAll(0, cube);
      final result = bindings.vd_lut_register(
          key.cast<Char>(), buffer.cast(), cube.length);
      if (result != 0) {
        throw EngineException('not a usable .cube file', code: result);
      }
    } finally {
      malloc.free(buffer);
      malloc.free(key);
    }
  }

  /// Every look the engine can grade with, in the order they were registered
  /// — which is the order they were handed over, and therefore the order a
  /// picker should offer them in.
  static List<String> get names => [
        for (var i = 0; i < bindings.vd_lut_count(); i++)
          bindings.vd_lut_name(i).cast<Utf8>().toDartString(),
      ];
}
