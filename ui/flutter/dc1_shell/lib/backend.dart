import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Client for the `dc1-backend` control plane.
///
/// The transport is plain HTTP/JSON over a Unix domain socket. There is no
/// TCP anywhere in this file, and there must never be: the USB host and any
/// Wi-Fi peer must not be able to reach the control plane. The socket path
/// is the only address this client knows.
const String kDefaultSocketPath = '/run/dc1-ui.sock';

/// Overridable for development: DC1_BACKEND_SOCKET=/tmp/dc1-ui.sock.
String backendSocketPath(Map<String, String> environment) {
  final String? override = environment['DC1_BACKEND_SOCKET'];
  if (override == null || override.isEmpty) {
    return kDefaultSocketPath;
  }
  return override;
}

/// True when something exists at [path] (a Unix socket is not a regular
/// file, so `File.existsSync` is not the right question to ask).
bool backendSocketPresent(String path) {
  try {
    return FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  } on FileSystemException {
    return false;
  }
}

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

class BackendClient {
  BackendClient({String? socketPath})
    : socketPath = socketPath ?? kDefaultSocketPath;

  final String socketPath;
  HttpClient? _http;

  HttpClient get _client {
    final HttpClient? existing = _http;
    if (existing != null) {
      return existing;
    }
    final HttpClient created = HttpClient();
    created.connectionTimeout = const Duration(seconds: 15);
    // Every request, whatever its URL says, goes to the Unix socket.
    created.connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) =>
        Socket.startConnect(
          InternetAddress(socketPath, type: InternetAddressType.unix),
          0,
        );
    _http = created;
    return created;
  }

  Uri _url(String path) => Uri.http('dc1-backend', path);

  void close() {
    _http?.close(force: true);
    _http = null;
  }

  Future<List<WifiNetwork>> scanWifi() async {
    final Object? decoded = await _requestJson('GET', '/wifi/scan', null);
    return _parseNetworks(decoded);
  }

  /// The PSK leaves this process only inside the request body of a request
  /// that goes to a mode-0600 Unix socket. It is never put on an argv, never
  /// logged, and never rendered.
  Future<void> connectWifi(String ssid, String psk) async {
    await _requestJson('POST', '/wifi/connect', <String, Object?>{
      'ssid': ssid,
      'psk': psk,
    });
  }

  Future<void> onboard({
    required String user,
    required String password,
    required String hostname,
    required String timezone,
  }) async {
    await _requestJson('POST', '/onboard', <String, Object?>{
      'user': user,
      'password': password,
      'hostname': hostname,
      'timezone': timezone,
    });
  }

  /// NDJSON progress stream: one JSON object per line, no framing beyond
  /// the newline. Malformed lines are skipped rather than killing the UI.
  Stream<ProgressEvent> events() async* {
    final HttpClientRequest request = await _client.getUrl(_url('/events'));
    request.headers.set(HttpHeaders.acceptHeader, 'application/x-ndjson');
    final HttpClientResponse response = await request.close();
    if (response.statusCode != 200) {
      await response.drain<Object?>();
      throw BackendException('GET /events failed (${response.statusCode})');
    }
    final Stream<String> lines = response
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final String line in lines) {
      final ProgressEvent? event = _parseEventLine(line);
      if (event != null) {
        yield event;
      }
    }
  }

  Future<Object?> _requestJson(
    String method,
    String path,
    Map<String, Object?>? payload,
  ) async {
    HttpClientRequest request;
    try {
      request = await _client.openUrl(method, _url(path));
    } on SocketException catch (error) {
      throw BackendException(
        'cannot reach $socketPath (${error.osError?.message ?? error.message})',
      );
    }
    if (payload != null) {
      final List<int> body = utf8.encode(jsonEncode(payload));
      request.headers.contentType = ContentType.json;
      request.headers.contentLength = body.length;
      request.add(body);
    } else {
      request.headers.contentLength = 0;
    }
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    final Object? decoded = _tryDecode(text);
    if (response.statusCode != 200) {
      throw BackendException(_errorMessage(decoded, response.statusCode, path));
    }
    if (decoded is Map<String, dynamic>) {
      final Object? ok = decoded['ok'];
      if (ok is bool && !ok) {
        throw BackendException(
          _errorMessage(decoded, response.statusCode, path),
        );
      }
    }
    return decoded;
  }

  static Object? _tryDecode(String text) {
    if (text.trim().isEmpty) {
      return null;
    }
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  static ProgressEvent? _parseEventLine(String line) {
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

  static String _errorMessage(Object? decoded, int statusCode, String path) {
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
  static List<WifiNetwork> _parseNetworks(Object? decoded) {
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
}
