import 'dart:async';

import 'package:flutter/foundation.dart';

import '../commands/document_store.dart';
import 'project_file.dart';

/// Writes the document to disk after every committed edit.
///
/// The product has no Save command: an edit is saved, full stop. Writes are
/// debounced so a drag produces one write rather than one per frame, and
/// coalesced so a write already in flight does not queue a stampede behind it.
class Autosaver {
  Autosaver({
    required this.store,
    required this.file,
    this.debounce = const Duration(milliseconds: 400),
    this.onError,
  });

  final DocumentStore store;
  final ProjectFile file;
  final Duration debounce;

  /// Called when a write fails. Autosave keeps running; the document stays
  /// dirty and the next edit retries.
  final void Function(Object error, StackTrace stack)? onError;

  Timer? _timer;
  Future<void>? _inFlight;
  bool _writeAgain = false;
  bool _started = false;

  /// Revision of the most recent successful write.
  int get lastSavedRevision => _lastSaved;
  int _lastSaved = 0;

  @visibleForTesting
  int writeCount = 0;

  void start() {
    if (_started) return;
    _started = true;
    _lastSaved = store.revision;
    store.addListener(_onChanged);
  }

  void _onChanged() {
    _timer?.cancel();
    _timer = Timer(debounce, _write);
  }

  /// Writes now, waiting for any in-flight write to finish first. Call before
  /// closing a project or quitting.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _write();
    await _inFlight;
  }

  Future<void> _write() async {
    if (_inFlight != null) {
      // A write is already running against an older revision; ask it to go
      // round again rather than starting a second concurrent write.
      _writeAgain = true;
      return;
    }
    if (store.revision == _lastSaved) return;

    final completer = Completer<void>();
    _inFlight = completer.future;
    try {
      while (true) {
        final revision = store.revision;
        final project = store.project;
        _writeAgain = false;
        await file.save(project);
        writeCount++;
        _lastSaved = revision;
        store.markSaved(revision);
        if (!_writeAgain || store.revision == _lastSaved) break;
      }
    } catch (error, stack) {
      onError?.call(error, stack);
    } finally {
      _inFlight = null;
      completer.complete();
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_started) store.removeListener(_onChanged);
    _started = false;
  }
}
