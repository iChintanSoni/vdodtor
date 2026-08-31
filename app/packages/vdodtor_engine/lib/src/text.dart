/// Typefaces, handed to the engine so it can draw captions.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

/// The engine's font catalogue.
///
/// Registration is per process, not per machine: the faces go into the
/// engine's own list rather than into the system font manager's, so running
/// vdodtor does not change which fonts the computer has. It also means the
/// list starts empty and stays empty until somebody fills it, which the app
/// does once at startup from its bundled assets.
abstract final class TextFonts {
  /// Registers one .ttf or .otf with the engine.
  ///
  /// Registering a family that is already there does nothing, so this is safe
  /// to call again after a hot restart. Throws [EngineException] if the bytes
  /// are not a font.
  static void register(Uint8List data) {
    final buffer = malloc<Uint8>(data.length);
    try {
      buffer.asTypedList(data.length).setAll(0, data);
      final result =
          bindings.vd_text_register_font(buffer.cast(), data.length);
      if (result != 0) {
        throw EngineException('not a usable font file', code: result);
      }
    } finally {
      malloc.free(buffer);
    }
  }

  /// Every family the engine can draw with, in the order they were registered
  /// — which is the order the files were handed over, and therefore the order
  /// a font picker should offer them in.
  ///
  /// These are the names the files call themselves, not the names they have on
  /// disk. A caption stores one of these, so renaming a file changes nothing
  /// and swapping a file for a different face with the same family name
  /// changes every caption using it, which is what a font pack update should
  /// do.
  static List<String> get families => [
        for (var i = 0; i < bindings.vd_text_font_count(); i++)
          bindings.vd_text_font_name(i).cast<Utf8>().toDartString(),
      ];
}
