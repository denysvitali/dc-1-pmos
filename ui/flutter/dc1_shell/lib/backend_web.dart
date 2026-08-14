import 'dart:async';

import 'backend.dart';

/// The web transport: an in-browser stand-in for `dc1-backend`, so the
/// onboarding flow can be exercised end-to-end from GitHub Pages with no
/// device and no backend. It is deliberately honest about being a mock --
/// the Wi-Fi scan returns canned networks, and provisioning runs a simulated
/// progress timeline ending in ONBOARDING COMPLETE.
///
/// There is no `dart:io` here and there never can be: Flutter web has no
/// filesystem, no sockets, and no `Platform`, so the real device transport in
/// `backend_io.dart` simply cannot compile for the web target.
class WebBackendClient implements BackendClient {
  WebBackendClient();

  bool _closed = false;

  @override
  void close() {
    _closed = true;
  }

  @override
  Future<List<WifiNetwork>> scanWifi() async {
    // A short pause so the "Scanning for networks..." state is visible, the
    // same beat the real `nmcli` scan takes on the device.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    if (_closed) {
      return const <WifiNetwork>[];
    }
    return const <WifiNetwork>[
      WifiNetwork(ssid: 'Daylight', signal: 84),
      WifiNetwork(ssid: 'Home Wi-Fi', signal: 67),
      WifiNetwork(ssid: 'CoffeeShop-5G', signal: 42),
      WifiNetwork(ssid: 'Neighbour', signal: 25),
    ];
  }

  @override
  Future<void> connectWifi(String ssid, String psk) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  @override
  Future<void> onboard({
    required String user,
    required String password,
    required String hostname,
    required String timezone,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  @override
  Future<void> finish() async {
    // The real backend reboots the device moments after replying. The web
    // mock has nothing to reboot, so it just resolves; the progress screen
    // treats success and transport-failure alike.
  }

  @override
  Stream<ProgressEvent> events() {
    // A canned timeline mirroring the installer's free-form vocabulary, so
    // the progress screen renders exactly what it would against a real
    // backend. Timed, not instant, so each state is briefly legible.
    const List<ProgressEvent> timeline = <ProgressEvent>[
      ProgressEvent(state: 'CONNECTING TO WI-FI', progress: 0.1),
      ProgressEvent(state: 'REQUESTING IP ADDRESS', progress: 0.25),
      ProgressEvent(state: 'PROVISIONING', progress: 0.45),
      ProgressEvent(state: 'HASHING PASSWORD', progress: 0.6),
      ProgressEvent(state: 'APPLYING USER', progress: 0.75),
      ProgressEvent(state: 'APPLYING HOSTNAME AND TIMEZONE', progress: 0.9),
      ProgressEvent(state: 'ONBOARDING COMPLETE', progress: 1.0),
    ];
    return Stream<ProgressEvent>.fromIterable(timeline)
        .asyncMap((ProgressEvent event) async {
          await Future<void>.delayed(const Duration(milliseconds: 450));
          return event;
        });
  }
}

/// The single entry point `main.dart` calls. The web build always runs the
/// onboarding flow against the mock (unless `?firstlight=1` is in the URL,
/// which mirrors the DC1_FIRST_LIGHT escape hatch). Takes no arguments so it
/// matches the `backend_io.dart` factory signature; the environment source
/// differs per platform and stays behind this conditional import.
BackendClient? createBackendClient() {
  if (Uri.base.queryParameters['firstlight'] == '1') {
    return null;
  }
  return WebBackendClient();
}
