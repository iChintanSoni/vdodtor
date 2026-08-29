import '../model/project.dart';

/// A single user-visible edit.
///
/// Commands are pure functions of the document: `apply` must not read the
/// clock, the filesystem, or any state outside [project]. That is what lets
/// undo be a snapshot swap and lets the same command be replayed in a test.
abstract base class EditCommand {
  const EditCommand();

  /// Shown in the undo menu, sentence case: "Move clip", "Delete clip".
  String get label;

  /// Returns the next document. Returning the *same instance* means the edit
  /// was a no-op, and the store will not dirty the document or push undo.
  Project apply(Project project);

  /// Folds a follow-up edit into this one so a drag produces one undo entry
  /// rather than one per mouse-move. Return null to refuse the merge, which
  /// is the safe default.
  EditCommand? mergeWith(EditCommand next) => null;
}

/// Raised when a command is asked to edit something that is not there. These
/// are programmer errors — the UI should not offer an edit that cannot apply.
final class EditException implements Exception {
  EditException(this.message);
  final String message;
  @override
  String toString() => 'EditException: $message';
}
