import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/platform_model.dart';
import 'http_transport.dart';
export 'package:http/http.dart' show Response;
export 'http_transport.dart' show HttpCancellation, HttpTransportException;

enum HttpMethod { get, post, put, delete }

class HttpService {
  static int _webActive = 0;

  Future<http.Response> sendRequest(
    Uri url,
    HttpMethod method, {
    Map<String, String>? headers,
    Object? body,
    HttpCancellation? cancellation,
    Duration budget = const Duration(seconds: 15),
  }) async {
    if (body != null && body is! String) {
      throw const HttpTransportException('invalid_request');
    }
    final text = body as String?;
    if (!url.hasAuthority ||
        !const ['http', 'https'].contains(url.scheme) ||
        url.userInfo.isNotEmpty ||
        url.hasFragment ||
        url.toString().length > 2048 ||
        utf8.encode(text ?? '').length > httpMaxBodyBytes) {
      throw const HttpTransportException('invalid_request');
    }
    final frozenHeaders = Map<String, String>.of(
      headers ?? {'Content-Type': 'application/json'},
    );
    if (utf8.encode(jsonEncode(frozenHeaders)).length > 16 * 1024 ||
        frozenHeaders.length > 64) {
      throw const HttpTransportException('invalid_headers');
    }
    final names = <String>{};
    for (final entry in frozenHeaders.entries.toList()) {
      final name = entry.key.toLowerCase();
      if (!names.add(name) ||
          const [
            'host',
            'connection',
            'proxy-connection',
            'transfer-encoding',
            'proxy-authorization',
          ].contains(name) ||
          entry.value.contains('\r') ||
          entry.value.contains('\n')) {
        throw const HttpTransportException('invalid_headers');
      }
      if (name == 'content-length') {
        if (int.tryParse(entry.value) != utf8.encode(text ?? '').length) {
          throw const HttpTransportException('invalid_headers');
        }
        frozenHeaders.remove(entry.key);
      }
    }
    if (kIsWeb) {
      if (_webActive >= 8) {
        throw const HttpTransportException('capacity_exhausted');
      }
      _webActive++;
      try {
        return await sendAbortableHttp(
          http.Client(),
          url,
          method.name.toUpperCase(),
          headers: frozenHeaders,
          body: text,
          cancellation: cancellation,
          budget: budget,
        );
      } finally {
        _webActive--;
      }
    }
    // One native path owns proxy, routing, cancellation and request identity.
    // An old option must not silently select a weaker unbounded implementation.
    return NativeHttpTransport(
      start: ({required url, required method, required header, body}) =>
          bind.mainHttpRequest(
            url: url,
            method: method,
            header: header,
            body: body,
          ),
      poll: (id) => bind.mainGetHttpStatus(requestId: id),
      cancel: (id) => bind.mainCancelHttpRequest(requestId: id),
      onCleanupFailure: () => debugPrint(
        'HTTP bridge cancellation unavailable; bounded native expiry remains active.',
      ),
    ).send(
      url,
      method.name.toUpperCase(),
      headers: frozenHeaders,
      body: text,
      cancellation: cancellation,
      budget: budget,
    );
  }
}

Future<http.Response> get(
  Uri url, {
  Map<String, String>? headers,
  HttpCancellation? cancellation,
}) => HttpService().sendRequest(
  url,
  HttpMethod.get,
  headers: headers,
  cancellation: cancellation,
);

Future<http.Response> post(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  HttpCancellation? cancellation,
}) => HttpService().sendRequest(
  url,
  HttpMethod.post,
  headers: headers,
  body: body,
  cancellation: cancellation,
);

Future<http.Response> put(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  HttpCancellation? cancellation,
}) => HttpService().sendRequest(
  url,
  HttpMethod.put,
  headers: headers,
  body: body,
  cancellation: cancellation,
);

Future<http.Response> delete(
  Uri url, {
  Map<String, String>? headers,
  Object? body,
  Encoding? encoding,
  HttpCancellation? cancellation,
}) => HttpService().sendRequest(
  url,
  HttpMethod.delete,
  headers: headers,
  body: body,
  cancellation: cancellation,
);
