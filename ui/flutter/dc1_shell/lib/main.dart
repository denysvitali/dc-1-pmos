import 'dart:io';

import 'package:flutter/material.dart';

import 'backend.dart';
import 'first_light.dart';
import 'onboarding.dart';

/// Entry point for the DC-1 shell.
///
/// Two modes, chosen once at startup:
///
///  * first light -- DC1_FIRST_LIGHT=1, or no backend socket at
///    /run/dc1-ui.sock (overridable with DC1_BACKEND_SOCKET). Draws the
///    Phase 1 screen and nothing else, so a panel bring-up run never
///    depends on dc1-backend being up.
///  * onboarding -- the Wi-Fi -> identity -> hostname -> timezone ->
///    confirm -> progress flow, talking to dc1-backend over the Unix
///    socket.
void main() {
  final Map<String, String> environment = Platform.environment;
  final String socketPath = backendSocketPath(environment);
  final bool forcedFirstLight = environment['DC1_FIRST_LIGHT'] == '1';

  if (forcedFirstLight || !backendSocketPresent(socketPath)) {
    runApp(const FirstLightApp());
    return;
  }

  runApp(OnboardingApp(client: BackendClient(socketPath: socketPath)));
}
