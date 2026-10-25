import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const httpMaxBodyBytes = 1024 * 1024;
final _requestId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

class HttpTransportException implements Exception {
  final String code;
  const HttpTransportException(this.code);
  @override
  String toString() => 'HTTP transport: $code';
}

class HttpCancellation {
  final _cancelled = Completer<void>();
  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

typedef NativeHttpStart =
    Future<String> Function({
      required String url,
      required String method,
      required String header,
      String? body,
    });

Map<String, dynamic> _envelope(String text, {String? id}) {
  if (text.length > 2 * httpMaxBodyBytes) {
    throw const HttpTransportException('invalid_response');
  }
  final Object? value;
  try {
    value = jsonDecode(text);
  } catch (_) {
    throw const HttpTransportException('invalid_response');
  }
  if (value is! Map<String, dynamic> ||
      value['http_bridge_version'] is! int ||
      value['http_bridge_version'] != 1 ||
      value['request_id'] is! String ||
      (id != null && value['request_id'] != id)) {
    throw const HttpTransportException('invalid_response');
  }
  return value;
}

Never _failure(Object? code) => throw HttpTransportException(
  const {
        'invalid_request',
        'request_too_large',
        'invalid_headers',
        'invalid_request_id',
        'runtime_unavailable',
        'client_configuration_invalid',
        'capacity_exhausted',
        'transport_failed',
        'invalid_response',
        'invalid_response_headers',
        'redirect_rejected',
        'response_too_large',
        'deadline',
        'worker_failed',
        'request_missing',
        'result_capacity_exhausted',
      }.contains(code)
      ? code as String
      : 'transport_failed',
);

http.Response _response(Map<String, dynamic> envelope) {
  final value = envelope['response'];
  if (envelope.length != 4 ||
      value is! Map<String, dynamic> ||
      value.length != 3 ||
      value['status_code'] is! int ||
      value['status_code'] < 100 ||
      value['status_code'] >= 600 ||
      value['headers'] is! Map<String, dynamic> ||
      value['body_base64'] is! String ||
      (value['body_base64'] as String).length >
          ((httpMaxBodyBytes + 2) ~/ 3) * 4) {
    throw const HttpTransportException('invalid_response');
  }
  final headers = <String, String>{};
  var headerBytes = 0;
  for (final entry in (value['headers'] as Map<String, dynamic>).entries) {
    if (entry.value is! String ||
        headers.containsKey(entry.key.toLowerCase())) {
      throw const HttpTransportException('invalid_response');
    }
    headerBytes +=
        utf8.encode(entry.key).length +
        utf8.encode(entry.value as String).length;
    if (headerBytes > 16 * 1024 || headers.length >= 64) {
      throw const HttpTransportException('invalid_response');
    }
    headers[entry.key.toLowerCase()] = entry.value;
  }
  final Uint8List bytes;
  try {
    bytes = base64Decode(value['body_base64']);
    if (base64Encode(bytes) != value['body_base64'] ||
        bytes.length > httpMaxBodyBytes) {
      throw const FormatException();
    }
  } catch (_) {
    throw const HttpTransportException('invalid_response');
  }
  if (value['status_code'] >= 300 && value['status_code'] < 400) {
    throw const HttpTransportException('redirect_rejected');
  }
  return http.Response.bytes(bytes, value['status_code'], headers: headers);
}

/// Exact request-ID consumption; a late admission is cancelled even if its
/// caller already timed out. No URL-based polling, retries or body logging.
class NativeHttpTransport {
  final NativeHttpStart start;
  final Future<String> Function(String) poll;
  final Future<void> Function(String) cancel;
  final void Function() onCleanupFailure;
  NativeHttpTransport({
    required this.start,
    required this.poll,
    required this.cancel,
    required this.onCleanupFailure,
  });

  Future<http.Response> send(
    Uri url,
    String method, {
    required Map<String, String> headers,
    String? body,
    HttpCancellation? cancellation,
    Duration budget = const Duration(seconds: 15),
  }) async {
    final stop = HttpCancellation();
    if (cancellation?.isCancelled == true) {
      throw const HttpTransportException('cancelled');
    }
    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then((_) => stop.cancel()));
    }
    if (budget <= Duration.zero || budget > const Duration(minutes: 10)) {
      throw const HttpTransportException('invalid_budget');
    }
    var finished = false;
    String? id;
    var consumed = false;
    Future<void> cleanup(String requestId) async {
      try {
        await cancel(requestId).timeout(const Duration(seconds: 1));
      } catch (_) {
        onCleanupFailure();
      } // Native worker deadline and sweeper remain authoritative.
    }

    Future<http.Response> operation() async {
      final accepted = _envelope(
        await start(
          url: url.toString(),
          method: method,
          header: jsonEncode(headers),
          body: body,
        ),
      );
      if (accepted['state'] == 'failed') _failure(accepted['code']);
      if (accepted.length != 3 ||
          accepted['state'] != 'accepted' ||
          _requestId.stringMatch(accepted['request_id']) !=
              accepted['request_id']) {
        throw const HttpTransportException('invalid_response');
      }
      id = accepted['request_id'];
      if (finished || stop.isCancelled) {
        await cleanup(id!);
        throw const HttpTransportException('cancelled');
      }
      while (!finished && !stop.isCancelled) {
        final value = _envelope(await poll(id!), id: id);
        if (value['state'] == 'complete') {
          consumed = true;
          return _response(value);
        }
        if (value['state'] == 'failed') {
          consumed = true;
          _failure(value['code']);
        }
        if (value.length != 3 || value['state'] != 'pending') {
          throw const HttpTransportException('invalid_response');
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      throw const HttpTransportException('cancelled');
    }

    try {
      return await Future.any<http.Response>([
        operation(),
        stop.whenCancelled.then(
          (_) => throw const HttpTransportException('cancelled'),
        ),
      ]).timeout(budget);
    } on TimeoutException {
      throw const HttpTransportException('deadline');
    } on HttpTransportException {
      rethrow;
    } catch (_) {
      throw const HttpTransportException('transport_failed');
    } finally {
      finished = true;
      stop.cancel();
      if (id != null && !consumed) await cleanup(id!);
    }
  }
}

/// Used by the Web implementation. AbortableRequest aborts fetch even while
/// streaming; closing a Future alone is not a resource-lifetime boundary.
Future<http.Response> sendAbortableHttp(
  http.Client client,
  Uri url,
  String method, {
  required Map<String, String> headers,
  String? body,
  HttpCancellation? cancellation,
  Duration budget = const Duration(seconds: 15),
}) async {
  final stop = HttpCancellation();
  if (cancellation?.isCancelled == true) {
    client.close();
    throw const HttpTransportException('cancelled');
  }
  if (budget <= Duration.zero || budget > const Duration(minutes: 10)) {
    client.close();
    throw const HttpTransportException('invalid_budget');
  }
  if (cancellation != null) {
    unawaited(cancellation.whenCancelled.then((_) => stop.cancel()));
  }
  var deadline = false;
  final timer = Timer(budget, () {
    deadline = true;
    stop.cancel();
  });
  Future<http.Response> read() async {
    final request =
        http.AbortableRequest(method, url, abortTrigger: stop.whenCancelled)
          ..followRedirects = false
          ..headers.addAll(headers);
    if (body != null) request.bodyBytes = utf8.encode(body);
    final response = await client.send(request);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw const HttpTransportException('redirect_rejected');
    }
    if ((response.contentLength ?? 0) > httpMaxBodyBytes) {
      throw const HttpTransportException('response_too_large');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (chunk.length > httpMaxBodyBytes - bytes.length) {
        throw const HttpTransportException('response_too_large');
      }
      bytes.add(chunk);
    }
    return http.Response.bytes(
      bytes.takeBytes(),
      response.statusCode,
      headers: response.headers,
    );
  }

  try {
    final response = await Future.any<http.Response>([
      read(),
      stop.whenCancelled.then(
        (_) => throw const HttpTransportException('cancelled'),
      ),
    ]).timeout(budget);
    return response;
  } on TimeoutException {
    throw const HttpTransportException('deadline');
  } on HttpTransportException catch (error) {
    if (deadline && error.code == 'cancelled') {
      throw const HttpTransportException('deadline');
    }
    rethrow;
  } catch (_) {
    throw const HttpTransportException('transport_failed');
  } finally {
    timer.cancel();
    stop.cancel();
    client.close();
  }
}
