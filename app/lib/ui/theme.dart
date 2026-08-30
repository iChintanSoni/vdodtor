import 'package:flutter/material.dart';

/// One palette, so the chooser and the editor read as the same app.
///
/// Dark, low-chroma and quiet: everything here sits next to the user's
/// footage, and an editor's chrome that competes with the picture is an editor
/// that lies about colour.
abstract final class VdColors {
  static const canvas = Color(0xFF16181C);
  static const panel = Color(0xFF1F2228);
  static const rail = Color(0xFF14161A);
  static const line = Color(0xFF2C3038);
  static const accent = Color(0xFF4C8DF6);
  static const text = Color(0xFFE7E9EE);
  static const dim = Color(0xFF9AA1AE);
  static const warn = Color(0xFFE0A23C);
}

ThemeData vdodtorTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: VdColors.accent,
    brightness: Brightness.dark,
  ).copyWith(
    surface: VdColors.canvas,
    onSurface: VdColors.text,
    primary: VdColors.accent,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: VdColors.canvas,
    dividerColor: VdColors.line,
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.4),
      bodyMedium: TextStyle(color: VdColors.text),
      bodySmall: TextStyle(color: VdColors.dim),
    ),
  );
}

/// The monospace face used for anything the eye has to compare across rows:
/// timecode, frame counts, milliseconds.
const TextStyle vdMono = TextStyle(fontFamily: 'Menlo', fontSize: 12);
