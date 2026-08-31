import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Every keyboard shortcut the editor has, as data.
///
/// One table rather than a map built inside `build()`, for two reasons. A
/// shortcut nobody can find is half a shortcut, and the only honest way to
/// list them is to generate the list from the thing that binds them — a
/// hand-written help sheet drifts the first time a key changes. And a map of
/// closures assembled during a build cannot be checked for the mistakes that
/// actually happen here, which are duplicates and omissions: two actions on
/// one chord, where whichever Flutter reaches first silently wins, and an
/// action with no key at all.
///
/// So the table below is const data with no callbacks in it. The screen
/// supplies one handler per [EditorAction] and [shortcutBindings] puts the two
/// together, refusing to do it if any action is unhandled.
enum EditorAction {
  playPause,
  nudgeBack,
  nudgeForward,
  skipBack,
  skipForward,
  previousCut,
  nextCut,
  goToStart,
  goToEnd,
  zoomIn,
  zoomOut,
  zoomToFit,
  split,
  addText,
  addShape,
  duplicate,
  detachAudio,
  delete,
  selectAll,
  clearSelection,
  copy,
  cut,
  paste,
  undo,
  redo,
  import,
  closeProject,
  showShortcuts,
}

/// The headings the help sheet groups by, in the order it shows them.
enum ShortcutGroup {
  playback('Playback'),
  navigation('Moving the playhead'),
  view('The view'),
  editing('Editing'),
  project('Project');

  const ShortcutGroup(this.title);
  final String title;
}

/// One action, the keys that reach it, and what to call it in the list.
@immutable
final class ShortcutSpec {
  const ShortcutSpec(this.action, this.keys, this.label, this.group);

  final EditorAction action;

  /// Synonyms for one action, all bound. The first is the one the help sheet
  /// shows: `⌘=` and `⌘+` are the same intention typed by different keyboards
  /// and listing both twice would be noise.
  final List<SingleActivator> keys;

  final String label;
  final ShortcutGroup group;
}

/// The table. Exactly one entry per [EditorAction]; a test asserts it.
const List<ShortcutSpec> editorShortcuts = [
  ShortcutSpec(EditorAction.playPause, [SingleActivator(LogicalKeyboardKey.space)],
      'Play or pause', ShortcutGroup.playback),

  // The arrow family, and the reason it is a family: unmodified is a frame,
  // which is the unit the playhead moves in; shift is a second, for covering
  // ground; and alt is the next edit point, which is what anyone scrubbing is
  // usually aiming at and the only one of the three a pointer cannot hit
  // exactly.
  ShortcutSpec(EditorAction.nudgeBack, [SingleActivator(LogicalKeyboardKey.arrowLeft)],
      'Back one frame', ShortcutGroup.navigation),
  ShortcutSpec(EditorAction.nudgeForward,
      [SingleActivator(LogicalKeyboardKey.arrowRight)],
      'Forward one frame', ShortcutGroup.navigation),
  ShortcutSpec(EditorAction.skipBack,
      [SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true)],
      'Back one second', ShortcutGroup.navigation),
  ShortcutSpec(EditorAction.skipForward,
      [SingleActivator(LogicalKeyboardKey.arrowRight, shift: true)],
      'Forward one second', ShortcutGroup.navigation),
  ShortcutSpec(EditorAction.previousCut,
      [SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true)],
      'To the previous cut', ShortcutGroup.navigation),
  ShortcutSpec(EditorAction.nextCut,
      [SingleActivator(LogicalKeyboardKey.arrowRight, alt: true)],
      'To the next cut', ShortcutGroup.navigation),
  ShortcutSpec(EditorAction.goToStart, [SingleActivator(LogicalKeyboardKey.home)],
      'To the start', ShortcutGroup.navigation),
  ShortcutSpec(EditorAction.goToEnd, [SingleActivator(LogicalKeyboardKey.end)],
      'To the end', ShortcutGroup.navigation),

  // Two chords each, because the key between `-` and `delete` is `=` and the
  // shortcut everyone thinks of is `⌘+` — which is that key with shift on it.
  // Binding one and not the other makes the shortcut work for half the people
  // who try it.
  ShortcutSpec(EditorAction.zoomIn, [
    SingleActivator(LogicalKeyboardKey.equal, meta: true),
    SingleActivator(LogicalKeyboardKey.equal, meta: true, shift: true),
    SingleActivator(LogicalKeyboardKey.numpadAdd, meta: true),
  ], 'Zoom in', ShortcutGroup.view),
  ShortcutSpec(EditorAction.zoomOut, [
    SingleActivator(LogicalKeyboardKey.minus, meta: true),
    SingleActivator(LogicalKeyboardKey.numpadSubtract, meta: true),
  ], 'Zoom out', ShortcutGroup.view),
  ShortcutSpec(EditorAction.zoomToFit,
      [SingleActivator(LogicalKeyboardKey.digit0, meta: true)],
      'Fit the whole timeline', ShortcutGroup.view),

  ShortcutSpec(EditorAction.split,
      [SingleActivator(LogicalKeyboardKey.keyB, meta: true)],
      'Split at the playhead', ShortcutGroup.editing),
  // ⌘T rather than a bare T: the timeline has no text field to steal a plain
  // letter from today, and it will the moment a clip can be renamed in place.
  ShortcutSpec(EditorAction.addText,
      [SingleActivator(LogicalKeyboardKey.keyT, meta: true)],
      'Add a caption at the playhead', ShortcutGroup.editing),
  // R for rectangle, beside T for text, and nothing in this editor renders on
  // demand for ⌘R to have meant first.
  ShortcutSpec(EditorAction.addShape,
      [SingleActivator(LogicalKeyboardKey.keyR, meta: true)],
      'Add a shape at the playhead', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.duplicate,
      [SingleActivator(LogicalKeyboardKey.keyD, meta: true)],
      'Duplicate', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.detachAudio,
      [SingleActivator(LogicalKeyboardKey.keyD, meta: true, shift: true)],
      'Detach audio', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.delete, [
    SingleActivator(LogicalKeyboardKey.delete),
    SingleActivator(LogicalKeyboardKey.backspace),
  ], 'Delete', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.selectAll,
      [SingleActivator(LogicalKeyboardKey.keyA, meta: true)],
      'Select everything', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.clearSelection,
      [SingleActivator(LogicalKeyboardKey.escape)],
      'Select nothing', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.copy,
      [SingleActivator(LogicalKeyboardKey.keyC, meta: true)],
      'Copy', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.cut,
      [SingleActivator(LogicalKeyboardKey.keyX, meta: true)],
      'Cut', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.paste,
      [SingleActivator(LogicalKeyboardKey.keyV, meta: true)],
      'Paste at the playhead', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.undo,
      [SingleActivator(LogicalKeyboardKey.keyZ, meta: true)],
      'Undo', ShortcutGroup.editing),
  ShortcutSpec(EditorAction.redo,
      [SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true)],
      'Redo', ShortcutGroup.editing),

  ShortcutSpec(EditorAction.import,
      [SingleActivator(LogicalKeyboardKey.keyI, meta: true)],
      'Import media…', ShortcutGroup.project),
  ShortcutSpec(EditorAction.closeProject,
      [SingleActivator(LogicalKeyboardKey.keyW, meta: true)],
      'Close the project', ShortcutGroup.project),
  // Not "Keyboard shortcuts", which is what the sheet this opens is called:
  // a row inside a list, naming the list, reads as though it does something
  // else.
  ShortcutSpec(EditorAction.showShortcuts, [
    SingleActivator(LogicalKeyboardKey.slash, meta: true),
    SingleActivator(LogicalKeyboardKey.slash, meta: true, shift: true),
  ], 'Shortcut list', ShortcutGroup.project),
];

/// Expands the table into the map `CallbackShortcuts` wants.
///
/// Throws if [handlers] is missing an action. That is deliberate: a shortcut
/// wired to nothing is a key that does nothing when pressed, which reads as a
/// broken editor rather than as a missing case, and it is exactly the failure
/// a new action introduces. Better to refuse to build the screen.
Map<ShortcutActivator, VoidCallback> shortcutBindings(
    Map<EditorAction, VoidCallback> handlers) {
  final out = <ShortcutActivator, VoidCallback>{};
  for (final spec in editorShortcuts) {
    final handler = handlers[spec.action];
    if (handler == null) {
      throw StateError('no handler for ${spec.action.name}');
    }
    for (final key in spec.keys) {
      out[key] = handler;
    }
  }
  return out;
}

/// A chord as someone would write it down: `⇧⌘Z`.
///
/// Modifiers in the order Apple prints them, which is the order they appear in
/// every menu on the machine — putting them in a different one makes a correct
/// list look wrong.
String describeChord(SingleActivator activator) {
  final buffer = StringBuffer();
  if (activator.control) buffer.write('⌃');
  if (activator.alt) buffer.write('⌥');
  if (activator.shift) buffer.write('⇧');
  if (activator.meta) buffer.write('⌘');
  buffer.write(_keyName(activator.trigger));
  return buffer.toString();
}

String _keyName(LogicalKeyboardKey key) => switch (key) {
      LogicalKeyboardKey.space => 'Space',
      LogicalKeyboardKey.arrowLeft => '←',
      LogicalKeyboardKey.arrowRight => '→',
      LogicalKeyboardKey.arrowUp => '↑',
      LogicalKeyboardKey.arrowDown => '↓',
      LogicalKeyboardKey.home => 'Home',
      LogicalKeyboardKey.end => 'End',
      LogicalKeyboardKey.delete => 'Del',
      LogicalKeyboardKey.backspace => '⌫',
      LogicalKeyboardKey.escape => 'Esc',
      LogicalKeyboardKey.equal => '=',
      LogicalKeyboardKey.minus => '−',
      LogicalKeyboardKey.slash => '/',
      LogicalKeyboardKey.numpadAdd => '+',
      LogicalKeyboardKey.numpadSubtract => '−',
      // keyA is "A", digit0 is "0"; the label is the last character of the
      // debug name, which is the only place Flutter keeps it.
      _ => key.keyLabel.isNotEmpty ? key.keyLabel.toUpperCase() : '?',
    };
