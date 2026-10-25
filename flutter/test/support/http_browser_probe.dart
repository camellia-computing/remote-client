import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:camellia_remote_app/utils/http_transport.dart';
import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;

@JS('CAMELLIA_HTTP_PROBE')
external set _probe(JSPromise<JSBoolean> value);
@JS('CAMELLIA_HTTP_STREAM_READY')
external JSBoolean get _streamReady;

void check(bool value, String code) {
  if (!value) throw StateError(code);
}

Future<void> rejects(Future<http.Response> future, String code) async {
  try {
    await future;
  } on HttpTransportException catch (error) {
    check(error.code == code, 'wrong_error_code');
    return;
  }
  throw StateError('expected_transport_failure');
}

Future<void> run() async {
  final response = await sendAbortableHttp(
    BrowserClient(),
    Uri.parse('https://management.invalid/success'),
    'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer test-only',
    },
    body: '{"note":"原生😀"}',
  );
  check(
    utf8.decode(response.bodyBytes) == '{"note":"原生😀"}',
    'response_byte_encoding',
  );
  await rejects(
    sendAbortableHttp(
      BrowserClient(),
      Uri.parse('https://management.invalid/stalled-headers'),
      'POST',
      headers: {},
      budget: const Duration(milliseconds: 20),
    ),
    'deadline',
  );
  final cancellation = HttpCancellation();
  final streamed = sendAbortableHttp(
    BrowserClient(),
    Uri.parse('https://management.invalid/stalled-body'),
    'POST',
    headers: {},
    cancellation: cancellation,
  );
  final expected = rejects(streamed, 'cancelled');
  for (var attempt = 0; attempt < 100 && !_streamReady.toDart; attempt++) {
    await Future<void>.delayed(Duration.zero);
  }
  check(_streamReady.toDart, 'stream_not_started');
  cancellation.cancel();
  await expected;
  await rejects(
    sendAbortableHttp(
      BrowserClient(),
      Uri.parse('https://management.invalid/oversize'),
      'POST',
      headers: {},
    ),
    'response_too_large',
  );
}

void main() {
  _probe = run().then((_) => true.toJS).toJS;
}
