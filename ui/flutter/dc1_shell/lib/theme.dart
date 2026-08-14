import 'package:flutter/material.dart';

/// The first-light background. Every screen shares it so the transition from
/// "the panel lit up" to "the shell is running" is invisible.
const Color kBackground = Color(0xFF101418);
const Color kSurface = Color(0xFF1A2029);
const Color kForeground = Color(0xFFE6EAEE);
const Color kMuted = Color(0xFF8A96A3);
const Color kAccent = Color(0xFF4FC3F7);
const Color kError = Color(0xFFEF5350);
const Color kOk = Color(0xFF66BB6A);

const TextStyle kFirstLightStyle = TextStyle(
  color: kForeground,
  fontSize: 96,
  fontWeight: FontWeight.bold,
  letterSpacing: 8,
);

const TextStyle kTitleStyle = TextStyle(
  color: kForeground,
  fontSize: 34,
  fontWeight: FontWeight.bold,
);

const TextStyle kSubtitleStyle = TextStyle(color: kMuted, fontSize: 18);
const TextStyle kBodyStyle = TextStyle(color: kForeground, fontSize: 22);
const TextStyle kInputStyle = TextStyle(color: kForeground, fontSize: 24);
const TextStyle kHintStyle = TextStyle(color: kMuted, fontSize: 22);
const TextStyle kErrorStyle = TextStyle(color: kError, fontSize: 18);
const TextStyle kButtonStyle = TextStyle(
  fontSize: 22,
  fontWeight: FontWeight.w600,
);

const BorderRadius kRadius = BorderRadius.all(Radius.circular(12));

ThemeData dc1Theme() {
  return ThemeData(
    colorScheme: const ColorScheme.dark(
      primary: kAccent,
      onPrimary: kBackground,
      secondary: kAccent,
      onSecondary: kBackground,
      surface: kSurface,
      onSurface: kForeground,
      error: kError,
      onError: kBackground,
    ),
    scaffoldBackgroundColor: kBackground,
  );
}
