import 'package:flutter/material.dart';

import 'backend.dart';
import 'backend_client.dart';
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
///    socket (device) or the in-browser mock (web).
///
/// [createBackendClient] is supplied by the conditional import in
/// `backend_client.dart`, so this entry point is identical on the device and
/// on the web: it never imports `dart:io`, `dart:html`, or anything else
/// platform-specific. Each transport reads its own environment inside the
/// factory.
void main() {
  final BackendClient? client = createBackendClient();

  if (client == null) {
    runApp(const FirstLightApp());
    return;
  }

  runApp(OnboardingApp(client: client));
}
