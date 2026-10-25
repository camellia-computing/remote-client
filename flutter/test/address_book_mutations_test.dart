import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camellia_remote_app/models/address_book_mutations.dart';
import 'package:flutter_test/flutter_test.dart';

const id = '03440000-0000-4000-8000-000000000001';
final scope = List.filled(64, 'a').join();

AddressBookMutationCommand command({
  Object? payload,
  int generation = 2,
  AddressBookMutationKind kind = AddressBookMutationKind.peerAdd,
  String operationId = id,
}) => AddressBookMutationCommand(
  kind: kind,
  apiBase: Uri.parse('https://management.invalid/remote'),
  guid: 'personal-7',
  expectedGeneration: generation,
  payload: payload ?? {'id': '123'},
  operationId: operationId,
);

Map<String, dynamic> receiptBody(
  AddressBookMutationCommand command, {
  int status = 200,
}) => {
  'response_schema_version': 1,
  'management_operation_receipt_version': 1,
  'operation_id': command.operationId,
  'operation': command.kind.operation,
  'request_digest': command.requestDigest,
  'result_digest': List.filled(64, 'b').join(),
  'operation_generation': 1,
  'requested': {'mutations': 1},
  'applied': {'mutations': status == 200 ? 1 : 0},
  if (status == 200) ...{
    'result': 'OK',
    'mutation_generation': command.expectedGeneration + 1,
    'mutation_generations': {command.guid: command.expectedGeneration + 1},
  } else ...{
    'code': 'resource_generation_conflict',
    'message': 'Resource changed',
    'retryable': false,
  },
};

AddressBookMutationResponse response(
  AddressBookMutationCommand command, {
  int status = 200,
  Map<String, dynamic>? body,
}) => AddressBookMutationResponse(status, {
  'Content-Type': 'application/json; charset=utf-8',
}, utf8.encode(jsonEncode(body ?? receiptBody(command, status: status))));

Matcher protocolError(String code) => throwsA(
  isA<AddressBookMutationException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);

AddressBookMutationResponse recoveredResponse(
  AddressBookMutationCommand command, {
  int status = 200,
  int originalStatus = 200,
  Map<String, dynamic>? receipt,
}) => AddressBookMutationResponse(
  status,
  {'Content-Type': 'application/json'},
  utf8.encode(
    jsonEncode({
      'response_schema_version': 1,
      'original_status_code': originalStatus,
      'receipt': receipt ?? receiptBody(command, status: originalStatus),
    }),
  ),
);

/// A test seam, not production persistence. The actual Native/Web adapters must
/// enforce this contract across processes/isolate engines/tabs and reloads.
class MemoryJournal implements AddressBookMutationJournal {
  PendingAddressBookOperation? pending;
  int reservations = 0;
  int acknowledgements = 0;
  bool rejectReserve = false;
  bool rejectAcknowledge = false;
  Future<void>? reservationGate;
  @override
  Future<List<PendingAddressBookOperation>> readPending() async =>
      pending == null ? [] : [pending!];
  @override
  Future<void> reserve(PendingAddressBookOperation operation) async {
    reservations++;
    if (reservationGate != null) await reservationGate;
    if (rejectReserve || pending != null) throw StateError('STORAGE-SECRET');
    pending = operation;
  }

  @override
  Future<void> acknowledge(PendingAddressBookOperation operation) async {
    acknowledgements++;
    if (rejectAcknowledge) throw StateError('STORAGE-SECRET');
    final current = pending;
    if (current == null) return;
    if (!current.matches(operation)) {
      throw StateError('STORAGE-SECRET');
    }
    pending = null;
  }
}

void main() {
  test(
    'async preflight runs after durable reserve; context loss sends nothing',
    () async {
      final journal = MemoryJournal();
      final entered = Completer<void>();
      final gate = Completer<bool>();
      var sends = 0;
      var current = scope;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => current,
        beforeSend: () {
          expect(journal.pending?.operationId, id);
          entered.complete();
          return gate.future;
        },
        send: (request) async {
          sends++;
          return response(request);
        },
      );
      final running = service.execute(command(), scope: scope);
      await entered.future;
      current = '';
      gate.complete(true);
      final outcome = await running;
      expect(outcome.state, AddressBookMutationState.notSent);
      expect(outcome.code, 'context_changed');
      expect(outcome.pendingCleanup, isFalse);
      expect(sends, 0);
      expect(journal.pending, isNull);
    },
  );

  test(
    'failed preflight is definitely unsent and clears only its own reservation',
    () async {
      for (final throws in [false, true]) {
        final journal = MemoryJournal();
        var sends = 0;
        final service = AddressBookMutationService(
          journal: journal,
          currentScope: () => scope,
          beforeSend: () async {
            if (throws) throw StateError('PRIVATE-ENDPOINT');
            return false;
          },
          send: (request) async {
            sends++;
            return response(request);
          },
        );
        final outcome = await service.execute(command(), scope: scope);
        expect(outcome.state, AddressBookMutationState.notSent);
        expect(outcome.code, 'context_changed');
        expect(sends, 0);
        expect(journal.pending, isNull);
      }
    },
  );

  test(
    'batch repeats async ownership check for every child, never retries intent',
    () async {
      final journal = MemoryJournal();
      var checks = 0;
      final sent = <AddressBookMutationCommand>[];
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        beforeSend: () async => ++checks == 1,
        send: (request) async {
          sent.add(request);
          return response(request);
        },
      );
      final batch = AddressBookMutationBatch(
        apiBase: Uri.parse('https://management.invalid/remote'),
        guid: 'personal-7',
        expectedGeneration: 2,
        inputs: List.generate(
          3,
          (i) => AddressBookMutationInput(AddressBookMutationKind.peerUpdate, {
            'id': '$i',
            'alias': 'new',
          }),
        ),
      );
      final outcome = await service.executeBatch(batch, scope: scope);
      expect(outcome.confirmed, 1);
      expect(outcome.notAttempted, 2);
      expect(outcome.unknownOperationIds, isEmpty);
      expect(sent.single.operationId, batch.commands.first.operationId);
      expect(checks, 2);
      expect(journal.pending, isNull);
    },
  );

  AddressBookMutationBatch batch(List<AddressBookMutationInput> inputs) =>
      AddressBookMutationBatch(
        apiBase: Uri.parse('https://management.invalid/remote'),
        guid: 'personal-7',
        expectedGeneration: 2,
        inputs: inputs,
      );
  List<AddressBookMutationInput> peers(int count) => List.generate(
    count,
    (index) => AddressBookMutationInput(AddressBookMutationKind.peerAdd, {
      'id': '${index + 1}',
    }),
  );
  test('Dart request digest matches the Python canonical-document corpus', () {
    final corpus = jsonDecode(
      File('test/fixtures/address_book_mutations_v1.json').readAsStringSync(),
    );
    expect(corpus['version'], 1);
    for (final vector in corpus['vectors']) {
      expect(
        addressBookRequestDigest(
          operation: vector['operation'],
          method: vector['method'],
          path: vector['path'],
          body: vector['body'],
          expectedGeneration: vector['expected_generation'],
        ),
        vector['request_digest'],
        reason: vector['name'],
      );
    }
  });

  test(
    'command freezes body, digest, headers and identity before any await',
    () {
      final payload = {
        'id': '123',
        'tags': ['first'],
      };
      final request = command(payload: payload);
      (payload['tags'] as List).add('later');
      expect(request.body, '{"id":"123","tags":["first"]}');
      expect(request.uri.path, '/remote/api/ab/peer/add/personal-7');
      expect(request.headers('test-token'), {
        'Authorization': 'Bearer test-token',
        'Content-Type': 'application/json',
        'Idempotency-Key': id,
        'If-Match': '"2"',
      });
      expect(request.kind.method, 'POST');
      expect(request.operationId, id);
    },
  );

  test(
    'persistent scope binds stable actor and normalized endpoint, not a bearer token',
    () {
      final first = addressBookMutationScope(
        Uri.parse('https://MANAGEMENT.invalid/remote/'),
        'personal-7',
      );
      expect(
        first,
        addressBookMutationScope(
          Uri.parse('https://management.invalid/remote'),
          'personal-7',
        ),
      );
      expect(
        first,
        isNot(
          addressBookMutationScope(
            Uri.parse('https://management.invalid/remote'),
            'personal-8',
          ),
        ),
      );
      expect(
        first,
        isNot(
          addressBookMutationScope(
            Uri.parse('https://another.invalid/remote'),
            'personal-7',
          ),
        ),
      );
      expect(
        first,
        isNot(
          addressBookMutationScope(
            Uri.parse('https://management.invalid/other'),
            'personal-7',
          ),
        ),
      );
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(first), isTrue);
      expect(
        () => addressBookMutationScope(
          Uri.parse('https://management.invalid'),
          'username',
        ),
        protocolError('invalid_scope'),
      );
    },
  );

  test(
    'UUID generator uses canonical random v4 identities without collisions in a bounded sample',
    () {
      final ids = List.generate(128, (_) => newAddressBookOperationId());
      expect(ids.toSet().length, 128);
      for (final value in ids) {
        expect(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ).hasMatch(value),
          isTrue,
        );
      }
    },
  );

  test(
    'invalid identities, insecure endpoints and resource exhaustion fail before send',
    () {
      for (final operationId in [
        '',
        'not-an-id',
        id.replaceFirst('0344', 'ab44').toUpperCase(),
        '$id\n',
        '03440000-0000-1000-8000-000000000001',
      ]) {
        expect(
          () => command(operationId: operationId),
          protocolError('invalid_operation_id'),
        );
      }
      for (final endpoint in [
        'http://management.invalid',
        'https://user:secret@management.invalid',
        'https://management.invalid?token=secret',
        'https://management.invalid/#secret',
        'file:///tmp/test',
      ]) {
        expect(
          () => AddressBookMutationCommand(
            kind: AddressBookMutationKind.tagDelete,
            apiBase: Uri.parse(endpoint),
            guid: 'personal-7',
            expectedGeneration: 0,
            payload: [],
          ),
          protocolError('invalid_request'),
        );
      }
      for (final generation in [-1, 9007199254740991]) {
        expect(
          () => command(generation: generation),
          protocolError('invalid_request'),
        );
      }
      expect(
        () => command(payload: {'bad': double.nan}),
        protocolError('invalid_payload'),
      );
      expect(
        () => command(payload: List.filled(1024 * 1024, 'x').join()),
        protocolError('request_too_large'),
      );
    },
  );

  test(
    'all content routes verify explicit receipts; nonempty success is not a null error',
    () {
      for (final kind in AddressBookMutationKind.values) {
        final request = command(kind: kind);
        final receipt = AddressBookMutationReceipt.verify(
          request,
          response(request),
        );
        expect(receipt.succeeded, isTrue);
        expect(receipt.generation, 3);
        expect(receipt.operationId, id);
        expect(receipt.rejectionCode, isNull);
      }
    },
  );

  test(
    'success receipt requires exact operation, request digest, counts and next generation',
    () {
      final request = command();
      for (final changes in [
        {'response_schema_version': null},
        {'management_operation_receipt_version': 2},
        {'operation_id': newAddressBookOperationId()},
        {'operation': 'address_book_tag_add'},
        {'request_digest': List.filled(64, '0').join()},
        {'result_digest': 'x'},
        {'operation_generation': 0},
        {'operation_generation': 9007199254740992},
        {
          'requested': {'mutations': 1, 'extra': 0},
        },
        {
          'applied': {'mutations': 0},
        },
        {
          'applied': {'mutations': true},
        },
        {'mutation_generation': 2},
        {'mutation_generation': 4},
        {
          'mutation_generations': {'another-book': 3},
        },
        {
          'mutation_generations': {'personal-7': 3, 'extra': 3},
        },
        {'result': 'partial'},
        {'error': 'SECRET'},
      ]) {
        expect(
          () => AddressBookMutationReceipt.verify(
            request,
            response(request, body: {...receiptBody(request), ...changes}),
          ),
          protocolError('invalid_receipt'),
          reason: '$changes',
        );
      }
    },
  );

  test(
    'valid 4xx rejected receipt is terminal zero-mutation, not an automatic retry',
    () {
      final request = command();
      final rejected = AddressBookMutationReceipt.verify(
        request,
        response(request, status: 409),
      );
      expect(rejected.succeeded, isFalse);
      expect(rejected.generation, isNull);
      expect(rejected.rejectionCode, 'resource_generation_conflict');
      for (final changes in [
        {'code': 'SECRET\n'},
        {'retryable': 1},
        {'message': ''},
        {
          'applied': {'mutations': 1},
        },
        {'result': 'OK'},
      ]) {
        expect(
          () => AddressBookMutationReceipt.verify(
            request,
            response(
              request,
              status: 409,
              body: {...receiptBody(request, status: 409), ...changes},
            ),
          ),
          protocolError('invalid_receipt'),
        );
      }
    },
  );

  test(
    'provider error message budget counts Unicode code points, not UTF-16 code units',
    () {
      final original = command();
      final body = {
        ...receiptBody(original, status: 409),
        'message': List.filled(256, '😀').join(),
      };
      expect(
        AddressBookMutationReceipt.verify(
          original,
          response(original, status: 409, body: body),
        ).succeeded,
        isFalse,
      );
      expect(
        () => AddressBookMutationReceipt.verify(
          original,
          response(
            original,
            status: 409,
            body: {...body, 'message': List.filled(257, '😀').join()},
          ),
        ),
        protocolError('invalid_receipt'),
      );
    },
  );

  test(
    'empty/HTML/invalid UTF8/oversize and 5xx never become confirmed success',
    () {
      final request = command();
      for (final wire in [
        AddressBookMutationResponse(200, {
          'content-type': 'application/json',
        }, []),
        AddressBookMutationResponse(200, {
          'content-type': 'text/html',
        }, utf8.encode('SECRET')),
        AddressBookMutationResponse(
          200,
          {'content-type': 'application/json'},
          [255],
        ),
        AddressBookMutationResponse(200, {
          'content-type': 'application/json',
        }, List.filled(1024 * 1024 + 1, 32)),
        response(request, status: 500),
        response(request, status: 302),
      ]) {
        expect(
          () => AddressBookMutationReceipt.verify(request, wire),
          protocolError('invalid_receipt'),
        );
      }
    },
  );

  test(
    'journal reservation completes before send and confirmation clears only that record',
    () async {
      final journal = MemoryJournal();
      final request = command();
      var sends = 0;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (request) async {
          sends++;
          expect(journal.pending?.operationId, request.operationId);
          expect(journal.pending?.scope, scope);
          return response(request);
        },
      );
      final result = await service.execute(request, scope: scope);
      expect(result.state, AddressBookMutationState.confirmed);
      expect(sends, 1);
      expect(journal.pending, isNull);
      expect(journal.acknowledgements, 1);
    },
  );

  test(
    'storage failure and scope change during reservation cause zero sends',
    () async {
      final journal = MemoryJournal()..rejectReserve = true;
      var activeScope = scope;
      var sends = 0;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => activeScope,
        send: (request) async {
          sends++;
          return response(request);
        },
      );
      var result = await service.execute(command(), scope: scope);
      expect(result.state, AddressBookMutationState.notSent);
      expect(result.code, 'journal_unavailable');
      journal.rejectReserve = false;
      final gate = Completer<void>();
      journal.reservationGate = gate.future;
      final attempt = service.execute(command(), scope: scope);
      activeScope = List.filled(64, 'c').join();
      gate.complete();
      result = await attempt;
      expect(result.state, AddressBookMutationState.notSent);
      expect(result.code, 'context_changed');
      expect(journal.pending, isNull);
      expect(sends, 0);
    },
  );

  test(
    'response loss preserves ID and blocks subsequent new-ID mutation without retry',
    () async {
      final journal = MemoryJournal();
      var sends = 0;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async {
          sends++;
          throw StateError('NETWORK-SECRET');
        },
      );
      final unknown = await service.execute(command(), scope: scope);
      expect(unknown.state, AddressBookMutationState.unknown);
      expect(unknown.operationId, id);
      expect(unknown.code, 'transport_failed');
      final blocked = await service.execute(
        command(operationId: newAddressBookOperationId()),
        scope: scope,
      );
      expect(blocked.state, AddressBookMutationState.notSent);
      expect(journal.pending?.operationId, id);
      expect(sends, 1);
    },
  );

  test(
    'late response after deadline cannot acknowledge or reopen mutation admission',
    () async {
      final journal = MemoryJournal();
      final pending = Completer<AddressBookMutationResponse>();
      var sends = 0;
      var cancelled = 0;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        cancelTransport: () {
          cancelled++;
        },
        send: (_) {
          sends++;
          return pending.future;
        },
      );
      final result = await service.execute(
        command(),
        scope: scope,
        budget: const Duration(milliseconds: 20),
      );
      expect(result.state, AddressBookMutationState.unknown);
      expect(result.code, 'deadline');
      expect(cancelled, 1);
      pending.complete(response(command()));
      await Future<void>.delayed(Duration.zero);
      expect(journal.acknowledgements, 0);
      expect(journal.pending?.operationId, id);
      expect(sends, 1);
    },
  );

  test(
    'storage cleanup failure preserves a received immutable success receipt',
    () async {
      final journal = MemoryJournal()..rejectAcknowledge = true;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (request) async => response(request),
      );
      final result = await service.execute(command(), scope: scope);
      expect(result.succeeded, isTrue);
      expect(result.receipt?.generation, 3);
      expect(result.pendingCleanup, isTrue);
      expect(journal.pending?.operationId, id);
    },
  );

  test('same service is reentrant-safe while persistence is pending', () async {
    final journal = MemoryJournal();
    final gate = Completer<void>();
    journal.reservationGate = gate.future;
    var sends = 0;
    final service = AddressBookMutationService(
      journal: journal,
      currentScope: () => scope,
      send: (request) async {
        sends++;
        return response(request);
      },
    );
    final first = service.execute(command(), scope: scope);
    final second = await service.execute(
      command(operationId: newAddressBookOperationId()),
      scope: scope,
    );
    expect(second.code, 'operation_busy');
    gate.complete();
    expect((await first).succeeded, isTrue);
    expect(journal.reservations, 1);
    expect(sends, 1);
  });

  test(
    'batch freezes every child and preflights the whole selection before any send',
    () {
      final payload = {
        'id': '1',
        'tags': ['original'],
      };
      final frozen = batch([
        AddressBookMutationInput(AddressBookMutationKind.peerAdd, payload),
        ...peers(2),
      ]);
      (payload['tags'] as List).add('changed');
      expect(frozen.commands.first.body, '{"id":"1","tags":["original"]}');
      expect(frozen.commands.map((request) => request.expectedGeneration), [
        2,
        3,
        4,
      ]);
      expect(
        frozen.commands.map((request) => request.operationId).toSet().length,
        3,
      );
      expect(() => frozen.commands.clear(), throwsUnsupportedError);
      expect(() => batch([]), protocolError('invalid_selection'));
      expect(() => batch(peers(1001)), protocolError('invalid_selection'));
      expect(
        () => batch([
          ...peers(1),
          const AddressBookMutationInput(
            AddressBookMutationKind.tagAdd,
            double.nan,
          ),
        ]),
        protocolError('invalid_payload'),
      );
    },
  );

  test(
    'batch keeps two confirmed, one unknown original ID and the remaining not attempted',
    () async {
      final journal = MemoryJournal();
      var sends = 0;
      final selection = batch(peers(4));
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (request) async {
          sends++;
          if (sends == 3) throw StateError('RESPONSE-LOST');
          return response(request);
        },
      );
      final result = await service.executeBatch(selection, scope: scope);
      expect(result.requested, 4);
      expect(result.confirmed, 2);
      expect(result.unknownOperationIds, [selection.commands[2].operationId]);
      expect(result.rejected, 0);
      expect(result.notAttempted, 1);
      expect(result.fullyConfirmed, isFalse);
      expect(sends, 3);
      expect(journal.pending?.operationId, selection.commands[2].operationId);
    },
  );

  test(
    'batch terminal rejection stops without promoting conflict generation or retrying',
    () async {
      final journal = MemoryJournal();
      var sends = 0;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (request) async {
          sends++;
          return response(request, status: sends == 2 ? 409 : 200);
        },
      );
      final result = await service.executeBatch(batch(peers(3)), scope: scope);
      expect(result.confirmed, 1);
      expect(result.rejected, 1);
      expect(result.unknownOperationIds, isEmpty);
      expect(result.notAttempted, 1);
      expect(journal.pending, isNull);
      expect(sends, 2);
    },
  );

  test(
    'batch cannot continue if clearing an acknowledged receipt failed',
    () async {
      final journal = MemoryJournal()..rejectAcknowledge = true;
      var sends = 0;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (request) async {
          sends++;
          return response(request);
        },
      );
      final result = await service.executeBatch(batch(peers(3)), scope: scope);
      expect(result.confirmed, 1);
      expect(result.notAttempted, 2);
      expect(result.pendingCleanup, isTrue);
      expect(sends, 1);
    },
  );

  test(
    'account switch after a confirmed child stops all remaining sends',
    () async {
      final journal = MemoryJournal();
      var activeScope = scope;
      var sends = 0;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => activeScope,
        send: (request) async {
          sends++;
          activeScope = List.filled(64, 'c').join();
          return response(request);
        },
      );
      final result = await service.executeBatch(batch(peers(3)), scope: scope);
      expect(result.confirmed, 1);
      expect(result.notAttempted, 2);
      expect(result.outcomes.last.code, 'context_changed');
      expect(journal.pending, isNull);
      expect(sends, 1);
    },
  );

  test(
    'timed-out reservation may finish later but must never trigger a POST or automatic acknowledgement',
    () async {
      final gate = Completer<void>();
      final journal = MemoryJournal()..reservationGate = gate.future;
      var sends = 0;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (request) async {
          sends++;
          return response(request);
        },
      );
      final result = await service.execute(
        command(),
        scope: scope,
        budget: const Duration(milliseconds: 10),
      );
      expect(result.state, AddressBookMutationState.notSent);
      expect(result.pendingCleanup, isTrue);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(journal.pending?.operationId, id);
      expect(journal.acknowledgements, 0);
      expect(sends, 0);
    },
  );

  test(
    'transport cannot smuggle exception text through a typed error code',
    () async {
      final journal = MemoryJournal();
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async =>
            throw const AddressBookMutationException('PASSWORD-CANARY'),
      );
      final result = await service.execute(command(), scope: scope);
      expect(result.state, AddressBookMutationState.unknown);
      expect(result.code, 'transport_failed');
      expect(journal.pending?.operationId, id);
    },
  );

  test(
    'unknown committed write recovers with one read of its original ID, never a new POST',
    () async {
      final journal = MemoryJournal();
      var sends = 0;
      final original = command();
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async {
          sends++;
          throw StateError('COMMIT-RESPONSE-LOST');
        },
      );
      expect(
        (await service.execute(original, scope: scope)).state,
        AddressBookMutationState.unknown,
      );
      final pending = journal.pending!;
      var reads = 0;
      final result = await service.recover(
        pending,
        apiBase: Uri.parse('https://management.invalid/remote'),
        read: (uri) async {
          reads++;
          expect(uri.path, '/remote/api/management-operations/$id');
          expect(uri.hasQuery, isFalse);
          return recoveredResponse(original);
        },
      );
      expect(result.resolved, isTrue);
      expect(result.receipt?.operation, original.kind.operation);
      expect(result.receipt?.guid, original.guid);
      expect(result.receipt?.generation, 3);
      expect(journal.pending, isNull);
      expect([sends, reads], [1, 1]);
    },
  );

  test(
    'restart recovery needs only metadata and accepts an immutable rejected receipt',
    () async {
      final original = command(payload: {'id': '123', 'alias': 'old intent'});
      final metadata = PendingAddressBookOperation.fromJson(
        PendingAddressBookOperation(id, scope, 1).toJson(),
      );
      final journal = MemoryJournal()..pending = metadata;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async => throw StateError('must_not_send'),
      );
      final result = await service.recover(
        metadata,
        apiBase: Uri.parse('https://management.invalid'),
        read: (_) async => recoveredResponse(original, originalStatus: 409),
      );
      expect(result.resolved, isTrue);
      expect(result.receipt?.succeeded, isFalse);
      expect(result.code, 'resource_generation_conflict');
      expect(journal.pending, isNull);
    },
  );

  test('scope mismatch before recovery prevents any receipt GET', () async {
    final metadata = PendingAddressBookOperation(id, scope, 1);
    final journal = MemoryJournal()..pending = metadata;
    var activeScope = scope;
    var reads = 0;
    final service = AddressBookMutationService(
      journal: journal,
      currentScope: () => activeScope,
      send: (_) async => throw StateError('must_not_send'),
    );
    activeScope = List.filled(64, 'c').join();
    final result = await service.recover(
      metadata,
      apiBase: Uri.parse('https://management.invalid'),
      read: (_) async {
        reads++;
        return recoveredResponse(command());
      },
    );
    expect(result.resolved, isFalse);
    expect(result.code, 'context_changed');
    expect(reads, 0);
    expect(journal.pending, metadata);
  });

  test(
    'receipt lookup still resolves if another window already acknowledged the original ID',
    () async {
      final metadata = PendingAddressBookOperation(id, scope, 1);
      final journal = MemoryJournal();
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async => throw StateError('must_not_send'),
      );
      final result = await service.recover(
        metadata,
        apiBase: Uri.parse('https://management.invalid'),
        read: (_) async => recoveredResponse(command()),
      );
      expect(result.resolved, isTrue);
      expect(result.pendingCleanup, isFalse);
      expect(journal.pending, isNull);
    },
  );

  test(
    'lookup of an older original receipt cannot acknowledge another window\'s new operation',
    () async {
      final metadata = PendingAddressBookOperation(id, scope, 1);
      final newer = PendingAddressBookOperation(
        newAddressBookOperationId(),
        scope,
        2,
      );
      final journal = MemoryJournal()..pending = newer;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async => throw StateError('must_not_send'),
      );
      final result = await service.recover(
        metadata,
        apiBase: Uri.parse('https://management.invalid'),
        read: (_) async => recoveredResponse(command()),
      );
      expect(result.resolved, isTrue);
      expect(result.pendingCleanup, isTrue);
      expect(journal.pending, newer);
    },
  );

  test(
    '404, revoked auth, server failure and receipt expiry never release the original unknown operation',
    () async {
      final metadata = PendingAddressBookOperation(id, scope, 1);
      final journal = MemoryJournal()..pending = metadata;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async => throw StateError('must_not_send'),
      );
      for (final status in [401, 403, 404, 500]) {
        final result = await service.recover(
          metadata,
          apiBase: Uri.parse('https://management.invalid'),
          read: (_) async => recoveredResponse(command(), status: status),
        );
        expect(result.resolved, isFalse);
        expect(
          result.code,
          status == 404
              ? 'operation_not_found'
              : status == 500
              ? 'recovery_unavailable'
              : 'recovery_denied',
        );
        expect(journal.pending, metadata);
      }
      expect(journal.acknowledgements, 0);
    },
  );

  test(
    'invalid or wrong-operation recovery receipts never acknowledge pending metadata',
    () async {
      final metadata = PendingAddressBookOperation(id, scope, 1);
      final journal = MemoryJournal()..pending = metadata;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async => throw StateError('must_not_send'),
      );
      final original = command();
      for (final changes in [
        {'operation_id': newAddressBookOperationId()},
        {'operation': 'address_book_profile_create'},
        {'request_digest': 'invalid'},
        {'management_operation_receipt_version': 2},
        {'mutation_generation': 0},
        {
          'mutation_generations': {'personal-7': 3, 'other': 3},
        },
        {
          'applied': {'mutations': 0},
        },
      ]) {
        final result = await service.recover(
          metadata,
          apiBase: Uri.parse('https://management.invalid'),
          read: (_) async => recoveredResponse(
            original,
            receipt: {...receiptBody(original), ...changes},
          ),
        );
        expect(result.resolved, isFalse);
        expect(result.code, 'invalid_receipt');
        expect(journal.pending, metadata);
      }
      final unknown = await service.recover(
        metadata,
        apiBase: Uri.parse('https://management.invalid'),
        read: (_) async => recoveredResponse(
          original,
          originalStatus: 409,
          receipt: {...receiptBody(original, status: 409), 'result': 'unknown'},
        ),
      );
      expect(unknown.resolved, isFalse);
      expect(journal.acknowledgements, 0);
    },
  );

  test(
    'a late receipt GET cannot clear the original record after the recovery deadline',
    () async {
      final metadata = PendingAddressBookOperation(id, scope, 1);
      final journal = MemoryJournal()..pending = metadata;
      final gate = Completer<AddressBookMutationResponse>();
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async => throw StateError('must_not_send'),
      );
      final result = await service.recover(
        metadata,
        apiBase: Uri.parse('https://management.invalid'),
        budget: const Duration(milliseconds: 20),
        read: (_) => gate.future,
      );
      expect(result.resolved, isFalse);
      expect(result.code, 'deadline');
      gate.complete(recoveredResponse(command()));
      await Future<void>.delayed(Duration.zero);
      expect(journal.acknowledgements, 0);
      expect(journal.pending, metadata);
    },
  );

  test(
    'recovery preserves the immutable outcome if durable cleanup fails',
    () async {
      final metadata = PendingAddressBookOperation(id, scope, 1);
      final journal = MemoryJournal()
        ..pending = metadata
        ..rejectAcknowledge = true;
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async => throw StateError('must_not_send'),
      );
      final result = await service.recover(
        metadata,
        apiBase: Uri.parse('https://management.invalid'),
        read: (_) async => recoveredResponse(command()),
      );
      expect(result.resolved, isTrue);
      expect(result.pendingCleanup, isTrue);
      expect(journal.pending, metadata);
      expect(
        (await service.execute(
          command(operationId: newAddressBookOperationId()),
          scope: scope,
        )).state,
        AddressBookMutationState.notSent,
      );
    },
  );

  test(
    'invalid protocol response is unknown and exposes no raw body or exception text',
    () async {
      final journal = MemoryJournal();
      final service = AddressBookMutationService(
        journal: journal,
        currentScope: () => scope,
        send: (_) async => AddressBookMutationResponse(200, {
          'Content-Type': 'text/html',
        }, utf8.encode('PASSWORD-CANARY')),
      );
      final result = await service.execute(command(), scope: scope);
      expect(result.state, AddressBookMutationState.unknown);
      expect(result.code, 'invalid_receipt');
      expect(journal.pending?.operationId, id);
    },
  );
}
