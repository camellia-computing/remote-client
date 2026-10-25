library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:camellia_remote_app/models/address_book_journal.dart';
import 'package:camellia_remote_app/models/address_book_journal_web.dart'
    show WebAddressBookMutationJournal;
import 'package:camellia_remote_app/models/address_book_mutations.dart';
import 'package:web/web.dart' as web;

@JS('CAMELLIA_JOURNAL_FAULT')
external set _fault(JSString value);
@JS('CAMELLIA_JOURNAL_PROBE')
external set _probe(JSPromise<JSBoolean> value);

void check(bool value, String code) {
  if (!value) throw StateError(code);
}

Future<void> rejects(Future<void> Function() operation, String expected) async {
  try {
    await operation();
  } on AddressBookMutationException catch (error) {
    check(error.code == expected, 'wrong_error_code');
    return;
  }
  throw StateError('expected_failure');
}

Future<void> run() async {
  final first = createAddressBookMutationJournal();
  final other = createAddressBookMutationJournal();
  final record = PendingAddressBookOperation(
    'ab440000-0000-4000-8000-000000000001',
    List.filled(64, 'a').join(),
    0,
  );
  check((await first.readPending()).isEmpty, 'initial_pending');
  await first.reserve(record);
  check(
    (await other.readPending()).single.matches(record),
    'reload_record_lost',
  );
  await rejects(() => other.reserve(record), 'journal_pending');
  await rejects(
    () => other.acknowledge(
      PendingAddressBookOperation(record.operationId, record.scope, 1),
    ),
    'journal_identity_conflict',
  );
  check(
    (await first.readPending()).single.matches(record),
    'wrong_ack_removed_record',
  );
  await first.acknowledge(record);
  check((await other.readPending()).isEmpty, 'ack_not_persisted');

  final second = PendingAddressBookOperation(
    'ab440000-0000-4000-8000-000000000002',
    record.scope,
    9007199254740991,
  );
  var successes = 0;
  final attempts = [first.reserve(record), other.reserve(second)].map((
    future,
  ) async {
    try {
      await future;
      successes++;
    } on AddressBookMutationException catch (error) {
      check(
        const ['journal_busy', 'journal_pending'].contains(error.code),
        'unexpected_competition_failure',
      );
    }
  });
  await Future.wait(attempts);
  check(successes == 1, 'two_writers_reserved');
  final winner = (await first.readPending()).single;
  await first.acknowledge(winner);

  final original = AddressBookMutationCommand(
    kind: AddressBookMutationKind.peerAdd,
    apiBase: Uri.parse('https://management.invalid'),
    guid: 'personal-7',
    expectedGeneration: 0,
    payload: {'id': '123'},
  );
  var sends = 0;
  final writer = AddressBookMutationService(
    journal: first,
    currentScope: () => record.scope,
    send: (_) async {
      sends++;
      throw StateError('commit_response_lost');
    },
  );
  check(
    (await writer.execute(original, scope: record.scope)).state ==
        AddressBookMutationState.unknown,
    'loss_reported_as_success',
  );
  final saved = (await other.readPending()).single;
  final restarted = AddressBookMutationService(
    journal: other,
    currentScope: () => record.scope,
    send: (_) async {
      sends++;
      throw StateError('must_not_replay');
    },
  );
  final recovered = await restarted.recover(
    saved,
    apiBase: Uri.parse('https://management.invalid'),
    read: (uri) async {
      check(
        uri.path == '/api/management-operations/${original.operationId}',
        'wrong_receipt_uri',
      );
      return AddressBookMutationResponse(
        200,
        {'Content-Type': 'application/json'},
        utf8.encode(
          jsonEncode({
            'response_schema_version': 1,
            'original_status_code': 200,
            'receipt': {
              'response_schema_version': 1,
              'management_operation_receipt_version': 2,
              'operation_id': original.operationId,
              'operation': original.kind.operation,
              'request_digest': original.requestDigest,
              'result_digest': List.filled(64, 'b').join(),
              'operation_generation': 1,
              'requested': {'mutations': 1},
              'applied': {'mutations': 1},
              'result': 'OK',
              'mutation_generation': 1,
              'mutation_generations': {'personal-7': 1},
            },
          }),
        ),
      );
    },
  );
  check(
    recovered.resolved && sends == 1 && (await first.readPending()).isEmpty,
    'restart_recovery_replayed_write',
  );

  for (final fault in ['quota', 'readback', 'locks']) {
    _fault = fault.toJS;
    var sends = 0;
    final service = AddressBookMutationService(
      journal: first,
      currentScope: () => record.scope,
      send: (_) async {
        sends++;
        throw StateError('must_not_send');
      },
    );
    final command = AddressBookMutationCommand(
      kind: AddressBookMutationKind.peerAdd,
      apiBase: Uri.parse('https://management.invalid'),
      guid: 'personal-7',
      expectedGeneration: 0,
      payload: {'id': '123'},
    );
    final result = await service.execute(command, scope: record.scope);
    check(
      result.state == AddressBookMutationState.notSent && sends == 0,
      'storage_failure_sent_post',
    );
    _fault = ''.toJS;
    check(
      (await first.readPending()).isEmpty,
      'failed_reservation_corrupted_state',
    );
  }

  web.window.localStorage.setItem(
    WebAddressBookMutationJournal.storageKey,
    '{corrupt-preserve',
  );
  await rejects(() async {
    await first.readPending();
  }, 'journal_corrupt');
  await rejects(() => first.reserve(record), 'journal_corrupt');
  check(
    web.window.localStorage.getItem(WebAddressBookMutationJournal.storageKey) ==
        '{corrupt-preserve',
    'corruption_was_erased',
  );
}

void main() {
  _probe = run().then((_) => true.toJS).toJS;
}
