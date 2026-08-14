import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend.dart';

/// The device transport: plain HTTP/JSON over a Unix domain socket. There is
/// no TCP anywhere in this file, and there must never be: the USB host and any
/// Wi-Fi peer must not be able to reach the control plane. The socket path is
/// the only address this client knows.

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

/// The single entry point `main.dart` calls. Returns the device client when a
/// backend socket is live and first light was not forced, null otherwise (null
/// means "show first light"). Reads the environment itself so `main.dart`
/// never imports `dart:io`.
BackendClient? createBackendClient() {
  final Map<String, String> environment = Platform.environment;
  if (environment['DC1_FIRST_LIGHT'] == '1') {
    return null;
  }
  final String path = backendSocketPath(environment);
  if (!backendSocketPresent(path)) {
    return null;
  }
  return IoBackendClient(socketPath: path);
}

class IoBackendClient implements BackendClient {
  IoBackendClient({String? socketPath})
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

  @override
  void close() {
    _http?.close(force: true);
    _http = null;
  }

  @override
  Future<List<WifiNetwork>> scanWifi() async {
    final Object? decoded = await _requestJson('GET', '/wifi/scan', null);
    return parseNetworks(decoded);
  }

  /// The PSK leaves this process only inside the request body of a request
  /// that goes to a mode-0600 Unix socket. It is never put on an argv, never
  /// logged, and never rendered.
  @override
  Future<void> connectWifi(String ssid, String psk) async {
    await _requestJson('POST', '/wifi/connect', <String, Object?>{
      'ssid': ssid,
      'psk': psk,
    });
  }

  @override
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

  @override
  Future<void> finish() async {
    await _requestJson('POST', '/finish', null);
  }

  @override
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
      final ProgressEvent? event = parseEventLine(line);
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
    final Object? decoded = tryDecodeJson(text);
    if (response.statusCode != 200) {
      throw BackendException(
        backendErrorMessage(decoded, response.statusCode, path),
      );
    }
    if (decoded is Map<String, dynamic>) {
      final Object? ok = decoded['ok'];
      if (ok is bool && !ok) {
        throw BackendException(
          backendErrorMessage(decoded, response.statusCode, path),
        );
      }
    }
    return decoded;
  }
}
