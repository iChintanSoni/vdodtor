/// Where the licence lives on this Mac.
///
/// One file holding one line: the key exactly as it was pasted. Not a
/// database, not the keychain, and not obfuscated.
///
/// **The keychain would be the wrong shape.** A licence is not a credential —
/// it is a receipt, and a receipt the user should be able to find, read and
/// copy back out when they set up their next machine. Putting it somewhere
/// only the app can reach would make "where is my licence key" a support
/// email instead of a Finder window.
///
/// **And obfuscating it would buy nothing.** A determined reader can patch
/// [Entitlement] in a hex editor in less time than any scrambling here would
/// take to write; what stops a *made-up* licence is the signature, and what
/// stops a *shared* one is that people who like a tool tend to pay for it.
/// This product is sold on not treating its buyers as suspects, and a file
/// they can read is the smallest way to say so.
library;

import 'dart:io';

/// Where a licence is kept. An interface with one implementation in the app,
/// because the sheet that pastes a key is a widget test away from the disk:
/// `testWidgets` runs its body under a fake clock, and a `dart:io` future
/// never completes there. A licence store the tests can supply is what lets
/// the sheet's behaviour be checked at all.
abstract interface class LicenceStore {
  /// The stored key, or null when there is none.
  Future<String?> read();

  Future<void> write(String key);

  Future<void> remove();
}

final class FileLicenceStore implements LicenceStore {
  const FileLicenceStore(this.file);

  final File file;

  File get _temporary => File('${file.path}.tmp');

  /// Null also when the file exists and cannot be read, because an
  /// unreadable licence and no licence leave the app in the same state and
  /// only one of them is worth a code path.
  @override
  Future<String?> read() async {
    try {
      if (!await file.exists()) return null;
      final text = (await file.readAsString()).trim();
      return text.isEmpty ? null : text;
    } on FileSystemException {
      return null;
    }
  }

  /// Writes through a temporary file so that a licence is never half on disk.
  /// Small stakes — the user still has the email — but the same sequence
  /// [ProjectFile] uses, and a licence that read back truncated would look
  /// like a forged one, which is the worst thing it could look like.
  @override
  Future<void> write(String key) async {
    await file.parent.create(recursive: true);
    final handle = await _temporary.open(mode: FileMode.writeOnly);
    try {
      await handle.writeString('${key.trim()}\n');
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _temporary.rename(file.path);
  }

  @override
  Future<void> remove() async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Nothing to do and nothing to say: the licence is gone from this
      // machine either way, and the caller has already been told it is.
    }
  }
}
