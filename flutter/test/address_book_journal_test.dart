import 'dart:convert';

import 'package:camellia_remote_app/models/address_book_journal_codec.dart';
import 'package:camellia_remote_app/models/address_book_journal_native.dart';
import 'package:camellia_remote_app/models/address_book_mutations.dart';
import 'package:flutter_test/flutter_test.dart';

const id = 'ab440000-0000-4000-8000-000000000001';
final record = PendingAddressBookOperation(
  id,
  List.filled(64, 'a').join(),
  1792858000000,
);
Matcher failed(String code) => throwsA(
  isA<AddressBookMutationException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);
String envelope(List<PendingAddressBookOperation> pending) => jsonEncode({
  'journal_version': 1,
  'code': 'ok',
  'pending': pending.map((entry) => entry.toJson()).toList(),
});

void main() {
  test(
    'journal metadata is bounded, canonical and excludes bodies, tokens, paths and request digests',
    () {
      final text = encodeAddressBookJournal([record]);
      final restored = decodeAddressBookJournal(text);
      expect(restored.single.matches(record), isTrue);
      expect(text.length, lessThan(400));
      expect(record.toJson().keys, ['operation_id', 'scope', 'created_at']);
      expect(() => restored.clear(), throwsUnsupportedError);
      expect(decodeAddressBookJournal(null), isEmpty);
      expect(decodeAddressBookJournal(encodeAddressBookJournal([])), isEmpty);
      expect(
        () => encodeAddressBookJournal([record, record]),
        failed('journal_corrupt'),
      );
    },
  );

  test(
    'old and future timestamps are display metadata, not automatic eviction',
    () {
      for (final time in [0, 1, 9007199254740991]) {
        final entry = PendingAddressBookOperation(id, record.scope, time);
        expect(
          decodeAddressBookJournal(
            encodeAddressBookJournal([entry]),
          ).single.createdAt,
          time,
        );
      }
    },
  );

  test(
    'corrupt, duplicate, imprecise or extended metadata is never silently repaired',
    () {
      final text = encodeAddressBookJournal([record]);
      for (final invalid in [
        '',
        '{',
        '$text ',
        text.replaceFirst('"journal_version":1', '"journal_version":2'),
        text.replaceFirst('1792858000000', '1792858000001'),
        text.replaceFirst('1792858000000', '1792858000000.0'),
        text.replaceFirst('"pending":', '"pending":[],"pending":'),
        text.replaceFirst('"created_at":', '"password":"canary","created_at":'),
        text.replaceFirst('"checksum":"', '"checksum":"0'),
        List.filled(4097, 'x').join(),
      ]) {
        expect(
          () => decodeAddressBookJournal(invalid),
          failed('journal_corrupt'),
        );
      }
      for (final changes in [
        {'scope': 'invalid'},
        {'operation_id': '$id\n'},
        {'created_at': -1},
        {'created_at': 1.5},
        {'created_at': 9007199254740992},
        {'request_digest': 'canary'},
      ]) {
        expect(
          () => PendingAddressBookOperation.fromJson({
            ...record.toJson(),
            ...changes,
          }),
          failed('invalid_journal_record'),
        );
      }
    },
  );

  test(
    'native calls pass only exact metadata and require the reserved echo before send',
    () async {
      final calls = <String>[];
      List<PendingAddressBookOperation> stored = [];
      final journal = NativeAddressBookMutationJournal(({
        required action,
        required operationId,
        required scope,
        required createdAtMs,
      }) async {
        calls.add(action);
        if (action == 'pending') {
          expect([operationId, scope, createdAtMs], ['', '', '']);
        } else {
          expect(
            [operationId, scope, createdAtMs],
            [id, record.scope, '${record.createdAt}'],
          );
          stored = action == 'reserve' ? [record] : [];
        }
        return envelope(stored);
      });
      expect(await journal.readPending(), isEmpty);
      await journal.reserve(record);
      expect((await journal.readPending()).single.matches(record), isTrue);
      await journal.acknowledge(record);
      expect(calls, ['pending', 'reserve', 'pending', 'acknowledge']);
    },
  );

  test(
    'native invalid echoes and nonempty acknowledgement never release admission',
    () async {
      final journal = NativeAddressBookMutationJournal(
        ({
          required action,
          required operationId,
          required scope,
          required createdAtMs,
        }) async => envelope(action == 'reserve' ? [] : [record]),
      );
      await expectLater(journal.reserve(record), failed('journal_corrupt'));
      await expectLater(journal.acknowledge(record), failed('journal_corrupt'));
    },
  );

  test(
    'native structured failures are bounded and raw bridge exceptions stay private',
    () async {
      for (final code in [
        'journal_busy',
        'journal_unavailable',
        'journal_corrupt',
        'journal_pending',
        'journal_identity_conflict',
        'invalid_journal_record',
      ]) {
        final journal = NativeAddressBookMutationJournal(
          ({
            required action,
            required operationId,
            required scope,
            required createdAtMs,
          }) async => jsonEncode({'journal_version': 1, 'code': code}),
        );
        await expectLater(journal.readPending(), failed(code));
      }
      final journal = NativeAddressBookMutationJournal(
        ({
          required action,
          required operationId,
          required scope,
          required createdAtMs,
        }) async => throw StateError('FILESYSTEM-PATH-TOKEN-CANARY'),
      );
      await expectLater(journal.readPending(), failed('journal_unavailable'));
    },
  );

  test(
    'native malformed schema, overflow and unsupported fields fail closed',
    () async {
      for (final text in [
        'not-json',
        '[]',
        '{}',
        List.filled(4097, 'x').join(),
        jsonEncode({'journal_version': 2, 'code': 'ok', 'pending': []}),
        jsonEncode({'journal_version': 1, 'code': 'canary'}),
        jsonEncode({
          'journal_version': 1,
          'code': 'ok',
          'pending': [],
          'extra': 'canary',
        }),
        envelope([record, record]),
        jsonEncode({
          'journal_version': 1,
          'code': 'ok',
          'pending': [
            {...record.toJson(), 'token': 'canary'},
          ],
        }),
      ]) {
        final journal = NativeAddressBookMutationJournal(
          ({
            required action,
            required operationId,
            required scope,
            required createdAtMs,
          }) async => text,
        );
        await expectLater(journal.readPending(), failed('journal_corrupt'));
      }
    },
  );
}
