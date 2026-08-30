import 'dart:io';

import 'package:flutter/services.dart';
import 'package:vdodtor_engine/vdodtor_engine.dart';

export 'package:vdodtor_engine/vdodtor_engine.dart'
    show GrantedFile, MediaDrop, ResolvedFile;

/// Permission to read the user's own files.
///
/// Everything else vdodtor touches lives somewhere the sandbox already grants.
/// Imported media does not, and the app has exactly two ways to be let in — an
/// open panel and a drop on the window — after which a security-scoped
/// bookmark is the only thing that survives a quit.
///
/// An interface rather than a call to the plugin, because the alternative is
/// that none of the import path can be tested without a window, a sandbox and
/// a user standing at the keyboard.
abstract interface class FileAccess {
  /// Asks the user for files. Empty when they cancel.
  Future<List<GrantedFile>> pick();

  /// Mints a bookmark for a file the app can already reach — after a drop, or
  /// for a file inside a dropped folder. Null when one cannot be made.
  Future<String?> bookmark(String path);

  /// Resolves a stored bookmark and opens the scope it names, which stays open
  /// until [release]. Null when the bookmark is unusable.
  Future<ResolvedFile?> resolve(String bookmark);

  /// Closes a scope opened by [resolve].
  Future<void> release(String path);
}

/// The real one: the open panel, the drop target and the bookmarks, over the
/// engine plugin's method channel.
final class SystemFileAccess implements FileAccess {
  const SystemFileAccess();

  /// The native half exists on macOS only. Elsewhere — and in a `flutter test`
  /// run, where no plugin is registered — every answer is "no access", which
  /// is the truth and leaves the app working rather than crashed.
  bool get _available => Platform.isMacOS;

  @override
  Future<List<GrantedFile>> pick() async {
    if (!_available) return const [];
    try {
      return await MediaAccess.pickFiles();
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<String?> bookmark(String path) async {
    if (!_available) return null;
    try {
      return await MediaAccess.bookmark(path);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<ResolvedFile?> resolve(String bookmark) async {
    if (!_available) return null;
    try {
      return await MediaAccess.resolveBookmark(bookmark);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> release(String path) async {
    if (!_available) return;
    try {
      await MediaAccess.stopAccess(path);
    } on MissingPluginException {
      // Nothing was ever opened; nothing to close.
    }
  }
}
