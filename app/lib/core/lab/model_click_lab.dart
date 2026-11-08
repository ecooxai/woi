import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../auth/auth.dart';
import '../auth/pkce_login.dart';

/// Only the synthetic lab API is exposed here. The host never receives Woi's
/// device-input tools, conversation history, or raw account credentials.
abstract class ModelClickLabBackend {
  Future<Map<String, Object?>> connection();
  Future<Map<String, Object?>> configureConnection(Map<String, Object?> input);
  Future<Map<String, Object?>> models({bool refresh = false});
  Future<Map<String, Object?>> trial(Map<String, Object?> input);
  Future<Map<String, Object?>> saveResult(Map<String, Object?> input);
  Future<void> close();
}

class ModelClickLabException implements Exception {
  const ModelClickLabException(this.code, this.message, {this.status = 400});

  final String code;
  final String message;
  final int status;

  @override
  String toString() => redactSecrets(message);
}

typedef ModelClickLabAssetLoader = Future<Uint8List> Function(String name);

/// App-owned loopback host for the same UI as the standalone model click lab.
/// A per-runtime token travels only in the launch fragment and API headers.
/// Opening a browser tab does not install a service or change authentication.
class ModelClickLab {
  ModelClickLab({
    required this.backend,
    PlatformUrlOpener? opener,
    ModelClickLabAssetLoader? loadAsset,
  }) : _opener = opener ?? defaultUrlOpener(),
       _loadAsset = loadAsset ?? _bundledAsset;

  final ModelClickLabBackend backend;
  final PlatformUrlOpener _opener;
  final ModelClickLabAssetLoader _loadAsset;

  static const _staticFiles = {
    '/': ('index.html', 'text/html; charset=utf-8'),
    '/index.html': ('index.html', 'text/html; charset=utf-8'),
    '/app.js': ('app.js', 'text/javascript; charset=utf-8'),
    '/app.css': ('app.css', 'text/css; charset=utf-8'),
  };
  static const _maxRequestBytes = 9 * 1024 * 1024;
  static const _maxResultBytes = 128 * 1024;
  static final _requestId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$');

  HttpServer? _server;
  Future<Uri>? _starting;
  Future<Uri>? _opening;
  Future<void>? _closing;
  bool _closed = false;
  String? _token;
  Map<String, Uint8List> _assets = const {};
  final _requestIds = <String>{};
  final _requestOrder = Queue<String>();
  int _activeTrials = 0;

  static Future<Uint8List> _bundledAsset(String name) async {
    final data = await rootBundle.load('assets/model_click_lab/$name');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Reuses a ready server and coalesces simultaneous launch requests. The
  /// future completes only after the browser accepts the local launch URL.
  Future<Uri> open() {
    if (_closed) return Future.error(_closedError());
    final pending = _opening;
    if (pending != null) return pending;
    late final Future<Uri> opening;
    opening = _open().whenComplete(() {
      if (identical(_opening, opening)) _opening = null;
    });
    _opening = opening;
    return opening;
  }

  Future<Uri> _open() async {
    final url = await _ensureServer();
    if (_closed) throw _closedError();
    bool opened;
    try {
      // Android's keepAlive option is reserved for sign-in and displays an
      // authentication notification. The lab is an ordinary app-owned page.
      opened = await _opener.open(url);
    } catch (_) {
      throw const ModelClickLabException(
        'browser_unavailable',
        'Woi could not open Model Click Lab. Check that a browser is available and try again.',
        status: 503,
      );
    }
    if (_closed) throw _closedError();
    if (!opened) {
      throw const ModelClickLabException(
        'browser_unavailable',
        'Woi could not open Model Click Lab. Check that a browser is available and try again.',
        status: 503,
      );
    }
    return url;
  }

  Future<Uri> _ensureServer() {
    final server = _server;
    if (server != null) return Future.value(_launchUrl(server));
    final pending = _starting;
    if (pending != null) return pending;
    late final Future<Uri> starting;
    starting = _start().whenComplete(() {
      if (identical(_starting, starting)) _starting = null;
    });
    _starting = starting;
    return starting;
  }

  Future<Uri> _start() async {
    final Map<String, Uint8List> assets;
    try {
      final names = _staticFiles.values.map((entry) => entry.$1).toSet();
      final entries = await Future.wait(
        names.map((name) async => MapEntry(name, await _loadAsset(name))),
      );
      assets = Map.fromEntries(entries);
      if (assets.values.any((data) => data.isEmpty)) {
        throw StateError('Empty lab asset');
      }
    } catch (_) {
      if (_closed) throw _closedError();
      throw const ModelClickLabException(
        'assets_unavailable',
        'Model Click Lab files are missing from this Woi installation. Reinstall the current build and try again.',
        status: 503,
      );
    }
    if (_closed) throw _closedError();
    final HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
    } catch (_) {
      throw const ModelClickLabException(
        'host_unavailable',
        'Woi could not start Model Click Lab on this device. Try again.',
        status: 503,
      );
    }
    if (_closed) {
      await server.close(force: true);
      throw _closedError();
    }
    _assets = assets;
    final random = Random.secure();
    _token = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    _server = server;
    server.listen(
      (request) => unawaited(_serve(request, server)),
      onError: (Object _) {},
      onDone: () {
        if (identical(_server, server)) {
          _server = null;
          _token = null;
        }
      },
    );
    return _launchUrl(server);
  }

  Uri _launchUrl(HttpServer server) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: server.port,
    path: '/',
    fragment: 'woi_lab_token=$_token',
  );

  static ModelClickLabException _closedError() => const ModelClickLabException(
    'lab_closed',
    'Model Click Lab has closed. Open Woi and try again.',
    status: 503,
  );

  void _checkRequest(HttpRequest request, HttpServer server) {
    if (_closed || !identical(_server, server)) throw _closedError();
    final host = '${InternetAddress.loopbackIPv4.address}:${server.port}';
    if (request.headers.value(HttpHeaders.hostHeader) != host) {
      throw const ModelClickLabException(
        'invalid_host',
        'Only the local lab address is accepted.',
        status: 403,
      );
    }
    // Android browsers can label an app-launched page as cross-site. Allow
    // only the public entry document's top-level navigation; it contains no
    // credentials or runtime token. Assets and APIs keep their origin guards.
    final entryNavigation =
        request.method == 'GET' &&
        const {'/', '/index.html'}.contains(request.uri.path) &&
        request.headers.value('sec-fetch-mode') == 'navigate' &&
        request.headers.value('sec-fetch-dest') == 'document';
    if (!entryNavigation) {
      final origin = request.headers.value('origin');
      if (origin != null && origin != 'http://$host') {
        throw const ModelClickLabException(
          'cross_origin',
          'Cross-origin lab requests are not accepted.',
          status: 403,
        );
      }
      final site = request.headers.value('sec-fetch-site');
      if (site != null && site != 'none' && site != 'same-origin') {
        throw const ModelClickLabException(
          'cross_origin',
          'Cross-origin lab requests are not accepted.',
          status: 403,
        );
      }
    }
    if (request.uri.path.startsWith('/api/')) {
      final expected = _token;
      final received = request.headers.value('x-woi-lab-token');
      if (!_sameToken(received, expected)) {
        throw const ModelClickLabException(
          'lab_authorization',
          'Open Model Click Lab from Woi Settings > Advanced to connect this page.',
          status: 403,
        );
      }
    }
  }

  static bool _sameToken(String? received, String? expected) {
    if (expected == null ||
        received == null ||
        expected.length != received.length) {
      return false;
    }
    var mismatch = 0;
    for (var i = 0; i < expected.length; i++) {
      mismatch |= expected.codeUnitAt(i) ^ received.codeUnitAt(i);
    }
    return mismatch == 0;
  }

  Future<Map<String, Object?>> _body(HttpRequest request) async {
    if (request.headers.contentType?.mimeType != 'application/json') {
      throw const ModelClickLabException(
        'invalid_content_type',
        'Use Content-Type: application/json.',
        status: 415,
      );
    }
    final declaredLength = request.contentLength;
    final limit = request.uri.path == '/api/result'
        ? _maxResultBytes
        : _maxRequestBytes;
    if (declaredLength == 0 || declaredLength > limit) {
      throw const ModelClickLabException(
        'request_too_large',
        'The lab request exceeds its size limit.',
        status: 413,
      );
    }
    final bytes = BytesBuilder(copy: false);
    final chunks = StreamIterator<List<int>>(request);
    final watch = Stopwatch()..start();
    try {
      while (true) {
        final remaining = const Duration(seconds: 30) - watch.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException('Lab body deadline');
        }
        if (!await chunks.moveNext().timeout(remaining)) break;
        final chunk = chunks.current;
        if (bytes.length + chunk.length > limit) {
          throw const ModelClickLabException(
            'request_too_large',
            'The lab request exceeds its size limit.',
            status: 413,
          );
        }
        bytes.add(chunk);
      }
      if (declaredLength >= 0 && bytes.length != declaredLength) {
        throw const ModelClickLabException(
          'truncated_body',
          'The lab request was incomplete.',
        );
      }
      final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (decoded is! Map<String, dynamic>) {
        throw const ModelClickLabException(
          'invalid_json',
          'A lab request must be a JSON object.',
        );
      }
      return decoded.cast<String, Object?>();
    } on TimeoutException {
      throw const ModelClickLabException(
        'request_timeout',
        'The lab request timed out.',
        status: 408,
      );
    } on FormatException {
      throw const ModelClickLabException(
        'invalid_json',
        'The lab request is not valid JSON.',
      );
    } finally {
      await chunks.cancel();
    }
  }

  String _validId(Map<String, Object?> input) {
    final id = input['request_id'];
    if (id is! String || !_requestId.hasMatch(id)) {
      throw const ModelClickLabException(
        'invalid_request_id',
        'Use a valid request_id for each lab attempt.',
      );
    }
    return id;
  }

  Future<void> _serve(HttpRequest request, HttpServer server) async {
    String? requestId;
    try {
      _checkRequest(request, server);
      final path = request.uri.path;
      if (request.method == 'GET') {
        final asset = _staticFiles[path];
        if (asset != null) {
          _send(request.response, 200, _assets[asset.$1]!, asset.$2);
        } else if (path == '/api/health') {
          _send(request.response, 200, {
            'ok': true,
            'protocol': 'screenshot-only-v3-tiers',
            'fresh_context': true,
            'image_detail_policy': 'auto',
            'server': 'woi-click-accuracy-lab',
          });
        } else if (path == '/api/connection') {
          _send(request.response, 200, await backend.connection());
        } else if (path == '/api/models') {
          _send(
            request.response,
            200,
            await backend.models(
              refresh: request.uri.queryParameters['refresh'] == '1',
            ),
          );
        } else {
          throw const ModelClickLabException(
            'not_found',
            'Not found.',
            status: 404,
          );
        }
      } else if (request.method == 'POST') {
        if (!const {
          '/api/connection',
          '/api/trial',
          '/api/result',
        }.contains(path)) {
          throw const ModelClickLabException(
            'not_found',
            'Not found.',
            status: 404,
          );
        }
        final input = await _body(request);
        // A shutdown or server replacement during the body upload must not
        // become a provider call after the user closed Woi.
        _checkRequest(request, server);
        if (path == '/api/connection') {
          _send(
            request.response,
            200,
            await backend.configureConnection(input),
          );
        } else if (path == '/api/result') {
          requestId = _validId(input);
          _send(request.response, 200, await backend.saveResult(input));
        } else {
          requestId = _validId(input);
          if (_activeTrials >= 3) {
            throw const ModelClickLabException(
              'lab_busy',
              'Three lab trials are already running. Try again shortly.',
              status: 429,
            );
          }
          if (!_requestIds.add(requestId)) {
            throw const ModelClickLabException(
              'duplicate_request',
              'Use a new request_id for every trial.',
              status: 409,
            );
          }
          _requestOrder.addLast(requestId);
          if (_requestOrder.length > 10000) {
            _requestIds.remove(_requestOrder.removeFirst());
          }
          _activeTrials++;
          try {
            _send(request.response, 200, await backend.trial(input));
          } finally {
            _activeTrials--;
          }
        }
      } else {
        throw const ModelClickLabException(
          'method_not_allowed',
          'This lab request method is not supported.',
          status: 405,
        );
      }
    } on ModelClickLabException catch (error) {
      _send(request.response, error.status, {
        'error': redactSecrets(error.message, [?_token]),
        'error_code': error.code,
        'request_id': ?requestId,
      });
    } catch (_) {
      _send(request.response, 500, {
        'error': 'The lab could not complete this request.',
        'error_code': 'internal_error',
        'request_id': ?requestId,
      });
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  void _send(
    HttpResponse response,
    int status,
    Object data, [
    String contentType = 'application/json; charset=utf-8',
  ]) {
    if (_closed) return;
    final bytes = switch (data) {
      Uint8List value => value,
      String value => utf8.encode(value),
      _ => utf8.encode(jsonEncode(data)),
    };
    try {
      response.statusCode = status;
      response.headers
        ..set(HttpHeaders.contentTypeHeader, contentType)
        ..set(HttpHeaders.cacheControlHeader, 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('Cross-Origin-Resource-Policy', 'same-origin')
        ..set(
          'Content-Security-Policy',
          "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
              "connect-src 'self'; font-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        );
      response.contentLength = bytes.length;
      response.add(bytes);
    } catch (_) {
      // The browser may leave while a provider request is completing.
    }
  }

  Future<void> close() {
    final pending = _closing;
    if (pending != null) return pending;
    _closed = true;
    _token = null;
    return _closing = _close();
  }

  Future<void> _close() async {
    final server = _server;
    _server = null;
    try {
      await server?.close(force: true);
    } finally {
      try {
        await backend.close();
      } finally {
        _assets = const {};
        _requestIds.clear();
        _requestOrder.clear();
      }
    }
  }
}
