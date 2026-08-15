import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'theme.dart';

/// What the touch keyboard does on this build target.
enum TouchKeyboardMode {
  /// Docked whenever a field is focused, and the fields stay ordinary
  /// editable [TextField]s so a USB keyboard still types. The device.
  docked,

  /// Never drawn. The browser preview runs on machines that already have a
  /// keyboard -- a physical one on a desktop, the OS one on a phone -- and a
  /// phone's keyboard slides in *over* the page, so drawing ours as well puts
  /// two keyboards on screen and hides the field they both serve.
  off,

  /// Docked, and the fields refuse host input so the OS keyboard never comes
  /// up over it. This is how you look at and use this keyboard from a phone.
  demo,
}

/// The mode for this build: [TouchKeyboardMode.docked] on the device, off in
/// the browser preview, [TouchKeyboardMode.demo] when the preview is opened
/// with `?keyboard=1` (the same URL-flag convention as `?firstlight=1`).
TouchKeyboardMode touchKeyboardMode() {
  if (!kIsWeb) {
    return TouchKeyboardMode.docked;
  }
  return Uri.base.queryParameters['keyboard'] == '1'
      ? TouchKeyboardMode.demo
      : TouchKeyboardMode.off;
}

/// An in-app touch keyboard.
///
/// The DC-1 has a touchscreen and no keys beyond power and volume, so without
/// this every text field in onboarding is a dead end: the user can focus
/// `username` and then has no way to enter a single character.
///
/// It is built into the app rather than pulled in as a Wayland input method
/// (squeekboard, wvkbd) on purpose:
///
///  * those need the compositor and the toolkit to agree on text-input-v3 /
///    virtual-keyboard-v1, and the Flutter GTK embedder's Wayland text-input
///    support is exactly the kind of thing that fails silently on a device
///    with no other way in;
///  * it keeps the runtime closure unchanged -- no extra package in the
///    rootfs, nothing new to start, nothing to order against sway;
///  * it renders in the same surface as the rest of the shell, so it inherits
///    the Panfrost path that first light already proved.
///
/// Physical keyboards keep working: the fields stay ordinary editable
/// [TextField]s, so a USB keyboard plugged in for debugging still types. The
/// one exception is [TouchKeyboardMode.demo], where the point is to prove
/// *this* keyboard and no other.
class Dc1KeyboardController extends ChangeNotifier {
  Dc1KeyboardController({this.mode = TouchKeyboardMode.docked});

  /// Fixed for the life of the app: it is a property of where the shell is
  /// running, not of the screen being drawn.
  final TouchKeyboardMode mode;

  TextEditingController? _target;
  ValueChanged<String>? _onChanged;
  VoidCallback? _onSubmitted;

  /// Whether a field is focused and the keyboard should be on screen.
  bool get attached => _target != null;

  /// Whether text fields must refuse input from the host, so that focusing
  /// one does not raise a second, real keyboard over this one.
  bool get suppressesHostInput => mode == TouchKeyboardMode.demo;

  /// Called by [Dc1TextField] when it takes focus.
  ///
  /// [onChanged] is threaded through because Flutter only fires
  /// `TextField.onChanged` for input that arrives through the text input
  /// client. Mutating the controller programmatically -- which is exactly what
  /// this keyboard does -- does not. Screens clear their validation error from
  /// `onChanged`, so without this a typo's error message would stay on screen
  /// while the user retyped.
  void attach(
    TextEditingController target, {
    ValueChanged<String>? onChanged,
    VoidCallback? onSubmitted,
  }) {
    if (mode == TouchKeyboardMode.off || identical(_target, target)) {
      return;
    }
    _target = target;
    _onChanged = onChanged;
    _onSubmitted = onSubmitted;
    notifyListeners();
  }

  /// Called when a field loses focus. Ignored if some other field has since
  /// taken over, so the keyboard does not flicker when focus moves directly
  /// from one field to the next.
  void detach(TextEditingController target) {
    if (!identical(_target, target)) {
      return;
    }
    _target = null;
    _onChanged = null;
    _onSubmitted = null;
    notifyListeners();
  }

  void _apply(String text, int cursor) {
    _target!.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: cursor),
    );
    _onChanged?.call(text);
  }

  /// Insert [s] at the cursor, replacing the selection if there is one.
  void insert(String s) {
    final TextEditingController? target = _target;
    if (target == null) {
      return;
    }
    final TextEditingValue value = target.value;
    final TextSelection selection = value.selection;
    if (!selection.isValid) {
      // No cursor yet (the field has never been touched): append.
      _apply(value.text + s, value.text.length + s.length);
      return;
    }
    _apply(
      value.text.replaceRange(selection.start, selection.end, s),
      selection.start + s.length,
    );
  }

  /// Delete the selection, or the character before the cursor.
  void backspace() {
    final TextEditingController? target = _target;
    if (target == null) {
      return;
    }
    final TextEditingValue value = target.value;
    final TextSelection selection = value.selection;
    if (!selection.isValid) {
      if (value.text.isEmpty) {
        return;
      }
      final String text = value.text.substring(0, value.text.length - 1);
      _apply(text, text.length);
      return;
    }
    if (selection.start != selection.end) {
      _apply(
        value.text.replaceRange(selection.start, selection.end, ''),
        selection.start,
      );
      return;
    }
    if (selection.start == 0) {
      return;
    }
    _apply(
      value.text.replaceRange(selection.start - 1, selection.start, ''),
      selection.start - 1,
    );
  }

  /// The Done key: same effect as submitting the field.
  void submit() => _onSubmitted?.call();
}

/// Makes the [Dc1KeyboardController] available to the text fields and to
/// [StepScaffold], which docks the keyboard when a field is focused.
class KeyboardScope extends InheritedNotifier<Dc1KeyboardController> {
  const KeyboardScope({
    required Dc1KeyboardController super.notifier,
    required super.child,
    super.key,
  });

  static Dc1KeyboardController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<KeyboardScope>()
        ?.notifier;
  }
}

const List<String> _digits = <String>[
  '1',
  '2',
  '3',
  '4',
  '5',
  '6',
  '7',
  '8',
  '9',
  '0',
];

const List<List<String>> _letters = <List<String>>[
  <String>['q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p'],
  <String>['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l'],
  <String>['z', 'x', 'c', 'v', 'b', 'n', 'm'],
];

/// The symbols a WPA passphrase, a hostname or a timezone can plausibly need.
const List<List<String>> _symbolRows = <List<String>>[
  <String>['!', '@', '#', r'$', '%', '^', '&', '*', '(', ')'],
  <String>['-', '_', '=', '+', '[', ']', '{', '}', ';', ':'],
  <String>[',', '.', '/', '?', "'", '"', '\\', '|', '<', '>'],
];

class Dc1Keyboard extends StatefulWidget {
  const Dc1Keyboard({required this.controller, super.key});

  final Dc1KeyboardController controller;

  @override
  State<Dc1Keyboard> createState() => _Dc1KeyboardState();
}

class _Dc1KeyboardState extends State<Dc1Keyboard> {
  bool _shift = false;
  bool _symbolLayer = false;

  void _type(String key) {
    widget.controller.insert(key);
    if (_shift) {
      // Shift is one-shot, like a phone keyboard: it applies to the next
      // character and then releases, so a capitalised first letter does not
      // silently turn the rest of the password into shouting.
      setState(() => _shift = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<List<String>> rows = _symbolLayer ? _symbolRows : _letters;
    // Keep the keyboard a predictable slice of the panel: big enough for
    // fingers, never so tall that the field it serves scrolls out of view.
    final double height = (MediaQuery.of(context).size.height * 0.42).clamp(
      240.0,
      520.0,
    );
    // TextFieldTapRegion puts the whole keyboard in the SAME tap group as the
    // text field it types into. Without it the keyboard is unusable, and the
    // failure is quietly total: EditableText wraps itself in a
    // TextFieldTapRegion whose default onTapOutside calls unfocus(), so a tap
    // on the keyboard counts as a tap OUTSIDE the field. The field unfocuses,
    // the focus listener detaches, the keyboard disappears mid-press -- and
    // because focus is already gone by the time the key's onTap runs, insert()
    // finds a nil target and drops the character too. One cause, both
    // symptoms; observed on the device 2026-08-15.
    //
    // ExcludeFocus below is a different guarantee and still needed: it stops
    // the keys THEMSELVES from taking focus. It does nothing about the field
    // giving focus up, which is what actually went wrong.
    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: SizedBox(
        height: height,
        child: Container(
          color: kSurface,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Column(
            children: <Widget>[
              _Row(
                children: <Widget>[
                  for (final String d in _digits)
                    _Key(label: d, onTap: () => _type(d)),
                ],
              ),
              for (final List<String> row in rows)
                _Row(
                  children: <Widget>[
                    for (final String k in row)
                      _Key(
                        label: _shift ? k.toUpperCase() : k,
                        onTap: () => _type(_shift ? k.toUpperCase() : k),
                      ),
                  ],
                ),
              _Row(
                children: <Widget>[
                  _Key(
                    // One-shot, like a phone keyboard: the accent fill says
                    // "armed" at a glance, and the label shouts with it.
                    label: _shift ? 'SHIFT' : 'shift',
                    flex: 3,
                    highlighted: _shift,
                    onTap: () => setState(() => _shift = !_shift),
                  ),
                  _Key(
                    label: _symbolLayer ? 'abc' : '?123',
                    flex: 3,
                    onTap: () => setState(() {
                      _symbolLayer = !_symbolLayer;
                      _shift = false;
                    }),
                  ),
                  _Key(
                    label: 'space',
                    flex: 8,
                    onTap: () => widget.controller.insert(' '),
                  ),
                  _Key(
                    label: '⌫',
                    flex: 3,
                    repeats: true,
                    onTap: widget.controller.backspace,
                  ),
                  _Key(
                    label: 'Done',
                    flex: 4,
                    accent: true,
                    onTap: widget.controller.submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// A single key. Owns its own pressed state so a press reads as a distinct
/// background rather than the ink splash alone (which is nearly invisible
/// against the dark surface), and -- for the backspace key -- repeats while
/// held.
class _Key extends StatefulWidget {
  const _Key({
    required this.label,
    required this.onTap,
    this.flex = 2,
    this.accent = false,
    this.highlighted = false,
    this.repeats = false,
  });

  final String label;
  final VoidCallback onTap;
  final int flex;
  final bool accent;
  final bool highlighted;

  /// Hold-to-repeat: fire once on press, then again ~450 ms later and every
  /// ~60 ms until release.
  final bool repeats;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  static const Duration _repeatDelay = Duration(milliseconds: 450);
  static const Duration _repeatInterval = Duration(milliseconds: 60);

  bool _pressed = false;
  Timer? _repeatTimer;

  @override
  void dispose() {
    _stopRepeat();
    super.dispose();
  }

  void _startRepeat() {
    _repeatTimer = Timer(_repeatDelay, () {
      _repeatTimer = Timer.periodic(_repeatInterval, (_) => widget.onTap());
    });
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  void _down() {
    setState(() => _pressed = true);
    if (widget.repeats) {
      widget.onTap();
      _startRepeat();
    }
  }

  void _up() {
    if (!_pressed) {
      // InkWell reports a cancelled press through both onTapCancel and
      // onTapUp; only the first one is a real release.
      return;
    }
    setState(() => _pressed = false);
    _stopRepeat();
  }

  @override
  Widget build(BuildContext context) {
    final Color background = _pressed
        ? widget.accent
              ? Color.lerp(kAccent, kForeground, 0.4)!
              : kAccent.withValues(alpha: 0.45)
        : widget.accent
        ? kAccent
        : widget.highlighted
        ? kAccent.withValues(alpha: 0.30)
        : kBackground;
    return Expanded(
      flex: widget.flex,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Material(
          color: background,
          borderRadius: kRadius,
          child: InkWell(
            borderRadius: kRadius,
            onTapDown: (_) => _down(),
            onTapUp: (_) => _up(),
            onTapCancel: _up,
            // A repeating key fires from _down() and its timers; firing
            // again on release would double the last deletion.
            onTap: widget.repeats ? () {} : widget.onTap,
            child: Center(
              child: Text(
                widget.label,
                style: TextStyle(
                  color: widget.accent
                      ? kBackground
                      : widget.highlighted
                      ? kAccent
                      : kForeground,
                  fontSize: 22,
                  fontWeight: widget.accent || widget.highlighted
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
