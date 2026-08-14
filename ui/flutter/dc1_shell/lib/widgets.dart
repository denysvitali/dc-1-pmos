import 'package:flutter/material.dart';

import 'keyboard.dart';
import 'theme.dart';

/// One onboarding step: title, optional subtitle, a body that owns the
/// remaining height, and a footer of full-width buttons. Touch-first: every
/// tap target is at least 64 logical pixels tall.
class StepScaffold extends StatelessWidget {
  const StepScaffold({
    required this.title,
    required this.body,
    this.subtitle,
    this.footer,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget body;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final String? subtitleText = subtitle;
    final Widget? footerWidget = footer;
    final Dc1KeyboardController? keyboard = KeyboardScope.maybeOf(context);
    return Scaffold(
      backgroundColor: kBackground,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(32, 28, 32, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(title, style: kTitleStyle),
              if (subtitleText != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(subtitleText, style: kSubtitleStyle),
                ),
              const SizedBox(height: 24),
              Expanded(child: body),
              if (footerWidget != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: footerWidget,
                ),
            ],
          ),
        ),
      ),
      // The touch keyboard is docked here rather than inside each screen so
      // every step that has a text field gets it from one place, and the
      // steps that do not (confirm, progress) never see it. It sits outside
      // the padded Column so it can span the full panel width, and pushes
      // nothing: the body above is already Expanded, so the layout simply
      // gets shorter while a field is focused.
      bottomNavigationBar: keyboard != null && keyboard.attached
          ? Dc1Keyboard(controller: keyboard)
          : null,
    );
  }
}

class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: kBackground,
        disabledBackgroundColor: kSurface,
        disabledForegroundColor: kMuted,
        minimumSize: const Size.fromHeight(72),
        textStyle: kButtonStyle,
        shape: const RoundedRectangleBorder(borderRadius: kRadius),
      ),
      child: Text(label),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    required this.label,
    required this.onPressed,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: kForeground,
        side: const BorderSide(color: kMuted),
        minimumSize: const Size.fromHeight(64),
        textStyle: kButtonStyle,
        shape: const RoundedRectangleBorder(borderRadius: kRadius),
      ),
      child: Text(label),
    );
  }
}

/// A full-width, left-aligned list row used for networks and timezones.
class OptionTile extends StatelessWidget {
  const OptionTile({
    required this.label,
    required this.onTap,
    this.trailing,
    this.selected = false,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final String? trailing;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final String? trailingText = trailing;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: selected ? kAccent : kSurface,
          foregroundColor: selected ? kBackground : kForeground,
          minimumSize: const Size.fromHeight(72),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          textStyle: kBodyStyle,
          shape: const RoundedRectangleBorder(borderRadius: kRadius),
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(label, overflow: TextOverflow.ellipsis, maxLines: 1),
            ),
            if (trailingText != null)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(
                  trailingText,
                  style: TextStyle(
                    fontSize: 18,
                    color: selected ? kBackground : kMuted,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class Dc1TextField extends StatefulWidget {
  const Dc1TextField({
    required this.controller,
    this.hintText,
    this.errorText,
    this.obscureText = false,
    this.autofocus = false,
    this.suffix,
    this.onChanged,
    this.onSubmitted,
    super.key,
  });

  final TextEditingController controller;
  final String? hintText;
  final String? errorText;
  final bool obscureText;
  final bool autofocus;
  final Widget? suffix;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<Dc1TextField> createState() => _Dc1TextFieldState();
}

class _Dc1TextFieldState extends State<Dc1TextField> {
  /// Owned here so the field can tell the touch keyboard when it is the one
  /// being typed into. Focus is the only signal available: the shell has no
  /// concept of a "current field" otherwise.
  final FocusNode _focusNode = FocusNode();

  /// Cached rather than looked up on demand: an inherited-widget lookup is
  /// illegal from dispose(), and that is exactly where the last detach has to
  /// happen.
  Dc1KeyboardController? _keyboard;

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_syncKeyboard);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _keyboard = KeyboardScope.maybeOf(context);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_syncKeyboard);
    // Detach before the node dies, or the keyboard keeps typing into a
    // controller that belongs to a screen that has already been popped.
    _keyboard?.detach(widget.controller);
    _focusNode.dispose();
    super.dispose();
  }

  void _syncKeyboard() {
    final Dc1KeyboardController? keyboard = _keyboard;
    if (keyboard == null) {
      return;
    }
    // Deferred by one frame on purpose. Attaching notifies the KeyboardScope,
    // which rebuilds StepScaffold -- and with `autofocus: true` this listener
    // fires while that same frame is still building, which would otherwise
    // throw "markNeedsBuild() called during build".
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (_focusNode.hasFocus) {
        keyboard.attach(
          widget.controller,
          onChanged: widget.onChanged,
          onSubmitted: () => widget.onSubmitted?.call(widget.controller.text),
        );
      } else {
        keyboard.detach(widget.controller);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      obscureText: widget.obscureText,
      autofocus: widget.autofocus,
      autocorrect: false,
      enableSuggestions: false,
      style: kInputStyle,
      cursorColor: kAccent,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle: kHintStyle,
        errorText: widget.errorText,
        errorStyle: kErrorStyle,
        errorMaxLines: 3,
        filled: true,
        fillColor: kSurface,
        suffixIcon: widget.suffix,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 22,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: kRadius,
          borderSide: BorderSide(color: kMuted),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: kRadius,
          borderSide: BorderSide(color: kAccent, width: 2),
        ),
        errorBorder: const OutlineInputBorder(
          borderRadius: kRadius,
          borderSide: BorderSide(color: kError),
        ),
        focusedErrorBorder: const OutlineInputBorder(
          borderRadius: kRadius,
          borderSide: BorderSide(color: kError, width: 2),
        ),
      ),
    );
  }
}

/// A validation message that is not attached to a text field.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(message, style: kErrorStyle),
    );
  }
}
