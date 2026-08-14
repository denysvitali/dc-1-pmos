import 'package:flutter/material.dart';

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

class Dc1TextField extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: false,
      style: kInputStyle,
      cursorColor: kAccent,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: kHintStyle,
        errorText: errorText,
        errorStyle: kErrorStyle,
        errorMaxLines: 3,
        filled: true,
        fillColor: kSurface,
        suffixIcon: suffix,
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
