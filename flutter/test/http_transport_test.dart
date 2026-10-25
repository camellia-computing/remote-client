import 'dart:async';
import 'dart:convert';

import 'package:camellia_remote_app/utils/http_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const firstId = '03440000-0000-4000-8000-000000000001';
const secondId = '03440000-0000-4000-8000-000000000002';
final uri = Uri.parse(
  'https://management.invalid/api/ab/peer/update/personal-1',
);
String envelope(String id, String state, [Map<String, Object>? extra]) =>
    jsonEncode({
      'http_bridge_version': 1,
      'request_id': id,
      'state': state,
      ...?extra,
    });
String complete(String id, String body, {int status = 200}) =>
    envelope(id, 'complete', {
      'response': {
        'status_code': status,
        'headers': {'content-type': 'application/json'},
        'body_base64': base64Encode(utf8.encode(body)),
      },
    });
Matcher error(String code) =>
    throwsA(isA<HttpTransportException>().having((e) => e.code, 'code', code));

class ProbeClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handle;
  bool closed = false;
  int sends = 0;
  ProbeClient(this.handle);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    return handle(request);
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test(
    'same URL requests consume only their own out-of-order identity',
    () async {
      final gates = {
        firstId: Completer<String>(),
        secondId: Completer<String>(),
      };
      final polled = <String>[];
      final cancelled = <String>[];
      final transport = NativeHttpTransport(
        start: ({required url, required method, required header, body}) async =>
            envelope(body == 'one' ? firstId : secondId, 'accepted'),
        poll: (id) {
          polled.add(id);
          return gates[id]!.future;
        },
        cancel: (id) async {
          cancelled.add(id);
        },
        onCleanupFailure: () => fail('cleanup failed'),
      );
      final first = transport.send(uri, 'PUT', headers: {}, body: 'one');
      final second = transport.send(uri, 'PUT', headers: {}, body: 'two');
      await Future<void>.delayed(Duration.zero);
      gates[secondId]!.complete(complete(secondId, 'two'));
      expect((await second).body, 'two');
      gates[firstId]!.complete(complete(firstId, 'one'));
      expect((await first).body, 'one');
      expect(polled, [firstId, secondId]);
      expect(cancelled, isEmpty);
    },
  );

  test(
    'late native admission after deadline is cancelled, never polled or retried',
    () async {
      final gate = Completer<String>();
      final cancelled = <String>[];
      var sends = 0;
      final transport = NativeHttpTransport(
        start: ({required url, required method, required header, body}) {
          sends++;
          return gate.future;
        },
        poll: (_) async => fail('late request polled'),
        cancel: (id) async {
          cancelled.add(id);
        },
        onCleanupFailure: () => fail('cleanup failed'),
      );
      await expectLater(
        transport.send(
          uri,
          'POST',
          headers: {},
          budget: const Duration(milliseconds: 5),
        ),
        error('deadline'),
      );
      gate.complete(envelope(firstId, 'accepted'));
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, [firstId]);
      expect(sends, 1);
    },
  );

  test(
    'explicit cancellation cancels original native ID while poll is outstanding',
    () async {
      final gate = Completer<String>();
      final cancellation = HttpCancellation();
      final cancelled = <String>[];
      final transport = NativeHttpTransport(
        start: ({required url, required method, required header, body}) async =>
            envelope(firstId, 'accepted'),
        poll: (_) => gate.future,
        cancel: (id) async {
          cancelled.add(id);
        },
        onCleanupFailure: () => fail('cleanup failed'),
      );
      final running = transport.send(
        uri,
        'DELETE',
        headers: {},
        cancellation: cancellation,
      );
      final expected = expectLater(running, error('cancelled'));
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel();
      await expected;
      expect(cancelled, [firstId]);
      gate.complete(complete(firstId, 'late'));
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'confirmed first child does not cancel the parent batch token',
    () async {
      final cancellation = HttpCancellation();
      var index = 0;
      final transport = NativeHttpTransport(
        start: ({required url, required method, required header, body}) async =>
            envelope(++index == 1 ? firstId : secondId, 'accepted'),
        poll: (id) async => complete(id, id),
        cancel: (_) async {},
        onCleanupFailure: () => fail('cleanup failed'),
      );
      expect(
        (await transport.send(
          uri,
          'PUT',
          headers: {},
          cancellation: cancellation,
        )).body,
        firstId,
      );
      expect(cancellation.isCancelled, false);
      expect(
        (await transport.send(
          uri,
          'PUT',
          headers: {},
          cancellation: cancellation,
        )).body,
        secondId,
      );
      cancellation.cancel();
    },
  );

  test(
    'wrong ID, invalid schema and raw HTML never become a usable response or diagnostic',
    () async {
      for (final body in [
        complete(secondId, 'PRIVATE-BODY'),
        '<html>PRIVATE-BODY</html>',
        jsonEncode({
          'http_bridge_version': 2,
          'request_id': firstId,
          'state': 'complete',
        }),
      ]) {
        var cleaned = false;
        final transport = NativeHttpTransport(
          start:
              ({required url, required method, required header, body}) async =>
                  envelope(firstId, 'accepted'),
          poll: (_) async => body,
          cancel: (_) async {
            cleaned = true;
          },
          onCleanupFailure: () => fail('cleanup failed'),
        );
        await expectLater(
          transport.send(uri, 'GET', headers: {}),
          error('invalid_response'),
        );
        expect(cleaned, true);
      }
    },
  );

  test(
    'native admission errors do not poll or echo arbitrary error fields',
    () async {
      final transport = NativeHttpTransport(
        start: ({required url, required method, required header, body}) async =>
            envelope('', 'failed', {'code': 'PRIVATE-PROXY-PASSWORD'}),
        poll: (_) async => fail('not admitted'),
        cancel: (_) async => fail('no original ID'),
        onCleanupFailure: () => fail('cleanup failed'),
      );
      await expectLater(
        transport.send(uri, 'GET', headers: {}),
        error('transport_failed'),
      );
    },
  );

  test(
    'native redirect is rejected and raw bytes preserve non-ASCII data',
    () async {
      final transport = NativeHttpTransport(
        start: ({required url, required method, required header, body}) async =>
            envelope(firstId, 'accepted'),
        poll: (_) async => complete(firstId, '原生😀'),
        cancel: (_) async {},
        onCleanupFailure: () {},
      );
      expect(
        (await transport.send(uri, 'PUT', headers: {})).bodyBytes,
        utf8.encode('原生😀'),
      );
      final redirect = NativeHttpTransport(
        start: ({required url, required method, required header, body}) async =>
            envelope(firstId, 'accepted'),
        poll: (_) async => complete(firstId, '', status: 302),
        cancel: (_) async {},
        onCleanupFailure: () {},
      );
      await expectLater(
        redirect.send(uri, 'PUT', headers: {}),
        error('redirect_rejected'),
      );
    },
  );

  test(
    'browser request is abortable, never follows redirects and closes after success',
    () async {
      http.BaseRequest? captured;
      final cancellation = HttpCancellation();
      final client = ProbeClient((request) async {
        captured = request;
        return http.StreamedResponse(Stream.value(utf8.encode('原生😀')), 200);
      });
      final response = await sendAbortableHttp(
        client,
        uri,
        'PUT',
        headers: {},
        body: 'body',
        cancellation: cancellation,
      );
      expect(response.bodyBytes, utf8.encode('原生😀'));
      expect(captured, isA<http.AbortableRequest>());
      expect(captured!.followRedirects, false);
      expect(client.closed, true);
      expect(cancellation.isCancelled, false);
      cancellation.cancel();
    },
  );

  test(
    'browser stalled response is aborted on deadline and never retried',
    () async {
      final stream = StreamController<List<int>>();
      late http.AbortableRequest captured;
      final client = ProbeClient((request) async {
        captured = request as http.AbortableRequest;
        return http.StreamedResponse(stream.stream, 200);
      });
      await expectLater(
        sendAbortableHttp(
          client,
          uri,
          'POST',
          headers: {},
          budget: const Duration(milliseconds: 5),
        ),
        error('deadline'),
      );
      await captured.abortTrigger;
      expect(client.closed, true);
      expect(client.sends, 1);
      // Substitute client is deliberately inert; real BrowserClient also aborts
      // its fetch/reader. Release the substitute stream so the test owns no task.
      await stream.close();
    },
  );

  test(
    'browser oversized streaming response aborts and closes without buffering all data',
    () async {
      final client = ProbeClient(
        (_) async => http.StreamedResponse(
          Stream.fromIterable([
            List.filled(httpMaxBodyBytes, 0),
            [1],
          ]),
          200,
        ),
      );
      await expectLater(
        sendAbortableHttp(client, uri, 'POST', headers: {}),
        error('response_too_large'),
      );
      expect(client.closed, true);
      expect(client.sends, 1);
    },
  );

  test(
    'pre-cancelled request and invalid budget never send browser traffic',
    () async {
      final cancellation = HttpCancellation()..cancel();
      for (final before in [true, false]) {
        final client = ProbeClient((_) async => fail('not sent'));
        await expectLater(
          sendAbortableHttp(
            client,
            uri,
            'GET',
            headers: {},
            cancellation: before ? cancellation : null,
            budget: before ? const Duration(seconds: 1) : Duration.zero,
          ),
          error(before ? 'cancelled' : 'invalid_budget'),
        );
        expect(client.closed, true);
        expect(client.sends, 0);
      }
    },
  );
}
