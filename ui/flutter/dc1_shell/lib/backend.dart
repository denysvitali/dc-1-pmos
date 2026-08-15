import 'dart:async';
import 'dart:convert';

/// Shared, platform-neutral types and parsing for the `dc1-backend` control
/// plane. The transport lives behind a conditional import in
/// `backend_client.dart`: `backend_io.dart` (Unix socket, `dart:io`) on the
/// device, `backend_web.dart` (an in-browser mock) on the web, where there is
/// no device backend to reach.
///
/// Nothing in this file may import `dart:io`: it is compiled for Flutter web,
/// and `dart:io` does not exist there.
const String kDefaultSocketPath = '/run/dc1-ui.sock';

class BackendException implements Exception {
  BackendException(this.message);

  final String message;

  @override
  String toString() => message;
}

class WifiNetwork {
  const WifiNetwork({required this.ssid, this.signal});

  final String ssid;
  final int? signal;
}

/// The backend's progress vocabulary is the installer's free-form uppercase
/// text, so failure and completion are recognised by substring: the states
/// that actually arrive are "ONBOARDING COMPLETE", "ONBOARDING FAILED",
/// "WI-FI CONNECTION FAILED", "ALREADY PROVISIONED", ...
bool stateIsFailure(String state) => state.contains('FAILED');

bool stateIsComplete(String state) =>
    state.contains('COMPLETE') || state.contains('ALREADY PROVISIONED');

bool stateIsTerminal(String state) =>
    stateIsFailure(state) || stateIsComplete(state);

/// One line of the `GET /events` NDJSON stream.
class ProgressEvent {
  const ProgressEvent({required this.state, this.message, this.progress});

  /// FETCHING / DOWNLOADING / VERIFYING / WRITING / COMPLETE / FAILED ...
  /// Free-form by design: the shell installer's status vocabulary is
  /// free-form uppercase text, and this stream mirrors it rather than
  /// inventing an enum the backend would have to translate into.
  final String state;
  final String? message;

  /// 0.0..1.0 when the backend knows a ratio, null for indeterminate.
  final double? progress;

  /// Terminal states are matched by substring, not equality: the backend
  /// publishes the installer's phrasing ("ONBOARDING COMPLETE",
  /// "ONBOARDING FAILED", "WI-FI CONNECTION FAILED"), and an equality test
  /// against bare COMPLETE/FAILED would silently never fire.
  bool get isFailure => stateIsFailure(state);
  bool get isTerminal => stateIsTerminal(state);

  static ProgressEvent? fromJson(Map<String, dynamic> json) {
    final Object? rawState = json['state'] ?? json['status'];
    if (rawState is! String || rawState.isEmpty) {
      return null;
    }
    final Object? rawMessage = json['message'] ?? json['detail'];
    final Object? rawProgress = json['progress'];
    double? progress;
    if (rawProgress is num) {
      progress = rawProgress.toDouble();
      if (progress < 0.0 || progress > 1.0) {
        progress = null;
      }
    }
    return ProgressEvent(
      state: rawState.toUpperCase(),
      message: rawMessage is String && rawMessage.isNotEmpty
          ? rawMessage
          : null,
      progress: progress,
    );
  }
}

/// The interface every transport implements. The screens take a
/// [BackendClient]; they never construct one, so the concrete choice
/// (Unix socket vs web mock) stays confined to `main.dart`.
abstract class BackendClient {
  /// The commit this build came from, for the footer line.
  ///
  /// Returns the empty string when it cannot be established -- a system
  /// installed before the version file shipped, or a payload that lost it.
  /// The empty string means "not known" and is rendered as such; it is never
  /// substituted with a placeholder, which on a panel would be
  /// indistinguishable from a build that really recorded that placeholder.
  /// Never throws: an unidentifiable build must not stop setup.
  Future<String> installerVersion();

  Future<List<WifiNetwork>> scanWifi();

  /// The PSK must never be logged, put on an argv, or rendered.
  Future<void> connectWifi(String ssid, String psk);

  Future<void> onboard({
    required String user,
    required String password,
    required String hostname,
    required String timezone,
  });

  /// Reboot into the system the user just described.
  ///
  /// Onboarding renames the autologin user and moves its home out from under
  /// the running Sway session, so there is nowhere for this session to go;
  /// the backend reboots shortly after replying. The call therefore either
  /// returns just before the device goes down or fails because it already
  /// did -- callers must treat a transport error here as success.
  Future<void> finish();

  /// NDJSON progress stream: one JSON object per line, no framing beyond
  /// the newline. Malformed lines are skipped rather than killing the UI.
  Stream<ProgressEvent> events();

  void close();
}

Object? tryDecodeJson(String text) {
  if (text.trim().isEmpty) {
    return null;
  }
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

ProgressEvent? parseEventLine(String line) {
  final String trimmed = line.trim();
  if (trimmed.isEmpty) {
    return null;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is Map<String, dynamic>) {
    return ProgressEvent.fromJson(decoded);
  }
  return null;
}

String backendErrorMessage(Object? decoded, int statusCode, String path) {
  if (decoded is Map<String, dynamic>) {
    final Object? error = decoded['error'] ?? decoded['message'];
    if (error is String && error.isNotEmpty) {
      return error;
    }
  }
  return '$path failed (HTTP $statusCode)';
}

/// Accepts either a bare list of SSID strings, a list of
/// `{"ssid":..,"signal":..}` objects, or `{"networks":[...]}`.
List<WifiNetwork> parseNetworks(Object? decoded) {
  Object? list = decoded;
  if (decoded is Map<String, dynamic>) {
    list = decoded['networks'] ?? decoded['ssids'] ?? decoded['results'];
  }
  if (list is! List<Object?>) {
    return const <WifiNetwork>[];
  }
  final List<WifiNetwork> networks = <WifiNetwork>[];
  final Set<String> seen = <String>{};
  for (final Object? entry in list) {
    String? ssid;
    int? signal;
    if (entry is String) {
      ssid = entry;
    } else if (entry is Map<String, dynamic>) {
      final Object? rawSsid = entry['ssid'] ?? entry['SSID'];
      if (rawSsid is String) {
        ssid = rawSsid;
      }
      final Object? rawSignal = entry['signal'] ?? entry['SIGNAL'];
      if (rawSignal is num) {
        signal = rawSignal.toInt();
      } else if (rawSignal is String) {
        signal = int.tryParse(rawSignal);
      }
    }
    if (ssid == null || ssid.isEmpty || !seen.add(ssid)) {
      continue;
    }
    networks.add(WifiNetwork(ssid: ssid, signal: signal));
  }
  return networks;
}
