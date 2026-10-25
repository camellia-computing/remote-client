import 'dart:async';
import 'dart:convert';

import 'package:camellia_remote_app/models/address_book_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

const guid = '03440000-0000-4000-8000-000000000001';

Map<String, dynamic> metadata({int generation = 2, String book = guid}) => {
  'address_book_snapshot_version': 1,
  'response_schema_version': 1,
  'guid': book,
  'authorization_generation': generation,
};

Map<String, dynamic> page(
  int current,
  int total,
  List<Object> data, {
  int generation = 2,
  String book = guid,
}) => {
  ...metadata(generation: generation, book: book),
  'pagination_contract_version': 1,
  'current': current,
  'pageSize': 100,
  'total': total,
  'data': data,
};

Map<String, dynamic> tags({int generation = 2, String book = guid}) => {
  ...metadata(generation: generation, book: book),
  'total': 1,
  'data': [
    {'name': 'team', 'color': 1},
  ],
};

Matcher fails(String code) => throwsA(
  isA<AddressBookSnapshotException>().having(
    (error) => error.code,
    'code',
    code,
  ),
);

Future<AddressBookContentSnapshot> load(
  List<Map<String, dynamic>> responses, {
  List<Uri>? calls,
}) {
  var index = 0;
  return AddressBookContentSnapshot.read(
    apiBase: Uri.parse('https://management.invalid/prefix'),
    guid: guid,
    request: (uri) async {
      calls?.add(uri);
      return responses[index++];
    },
  );
}

void main() {
  test(
    'complete snapshot binds all pages and tags to one generation and GUID',
    () async {
      final calls = <Uri>[];
      final first = List.generate(100, (index) => {'id': 'peer-$index'});
      final snapshot = await load([
        page(1, 101, first),
        page(2, 101, [
          {'id': 'last'},
        ]),
        tags(),
      ], calls: calls);
      expect(snapshot.identity.generation, 2);
      expect(snapshot.identity.guid, guid);
      expect(snapshot.peers.length, 101);
      expect(snapshot.tags.single['name'], 'team');
      expect(calls.first.path, '/prefix/api/ab/peers');
      expect(calls.first.queryParameters, {
        'ab': guid,
        'current': '1',
        'pageSize': '100',
      });
      expect(calls.last.path, '/prefix/api/ab/tags/$guid');
      expect(() => snapshot.peers.clear(), throwsUnsupportedError);
    },
  );

  test('zero peers still requires a matching tags response', () async {
    expect((await load([page(1, 0, []), tags()])).peers, isEmpty);
  });

  test('does not adopt a newer tag generation behind an editor', () async {
    await expectLater(
      load([page(1, 0, []), tags(generation: 3)]),
      fails('snapshot_changed'),
    );
  });

  test(
    'mixed peer pages fail without continuing or promoting a partial cache',
    () async {
      final calls = <Uri>[];
      await expectLater(
        load([
          page(1, 101, List.generate(100, (index) => {'id': '$index'})),
          page(2, 101, [
            {'id': 'last'},
          ], generation: 3),
          tags(),
        ], calls: calls),
        fails('snapshot_changed'),
      );
      expect(calls.length, 2);
    },
  );

  test('wrong profile response cannot replace the requested book', () async {
    await expectLater(
      load([page(1, 0, [], book: 'personal-other')]),
      fails('wrong_profile'),
    );
  });

  test(
    'short page fails instead of silently deleting uncopied peers',
    () async {
      await expectLater(
        load([
          page(1, 2, [
            {'id': 'one'},
          ]),
        ]),
        fails('incomplete_page'),
      );
    },
  );

  test(
    'duplicate and invalid peer identities fail the entire snapshot',
    () async {
      for (final peers in [
        [
          {'id': 'one'},
          {'id': 'one'},
        ],
        [
          {'id': ''},
        ],
        ['not-a-peer'],
      ]) {
        await expectLater(
          load([page(1, peers.length, peers)]),
          fails('invalid_peer'),
        );
      }
    },
  );

  test(
    'invalid pagination metadata and unbounded totals are rejected',
    () async {
      for (final changes in [
        {'total': -1},
        {'total': 10001},
        {'total': 1.5},
        {'current': 2},
        {'pageSize': 99},
        {'pagination_contract_version': 2},
        {'data': {}},
      ]) {
        await expectLater(
          load([
            {...page(1, 0, []), ...changes},
          ]),
          fails('invalid_page'),
        );
      }
    },
  );

  test('tag shape, count, duplicates and color bounds are checked', () async {
    for (final changes in [
      {'total': 2},
      {'total': 1.0},
      {'data': []},
      {
        'data': [
          {'name': '', 'color': 1},
        ],
      },
      {
        'data': [
          {'name': 'x', 'color': -1},
        ],
      },
      {
        'data': [
          {'name': 'x', 'color': 4294967296},
        ],
      },
    ]) {
      await expectLater(
        load([
          page(1, 0, []),
          {...tags(), ...changes},
        ]),
        throwsA(isA<AddressBookSnapshotException>()),
      );
    }
    await expectLater(
      load([
        page(1, 0, []),
        {
          ...tags(),
          'total': 2,
          'data': [
            {'name': 'x', 'color': 1},
            {'name': 'x', 'color': 2},
          ],
        },
      ]),
      fails('invalid_tag'),
    );
  });

  test(
    'generation must be explicit, nonnegative and exactly representable on Web',
    () {
      for (final generation in [null, -1, 2.0, '2', true, 9007199254740992]) {
        expect(
          () => AddressBookSnapshotIdentity.parse({
            ...metadata(),
            'authorization_generation': generation,
          }),
          fails('invalid_identity'),
        );
      }
      expect(
        AddressBookSnapshotIdentity.parse({
          ...metadata(),
          'authorization_generation': 0,
        }).generation,
        0,
      );
    },
  );

  test('old or future version is not silently accepted', () {
    for (final version in [null, 0, 2, '1']) {
      expect(
        () => AddressBookSnapshotIdentity.parse({
          ...metadata(),
          'address_book_snapshot_version': version,
        }),
        fails('unsupported_version'),
      );
    }
  });

  test(
    'safe HTTP decoder rejects HTML, malformed UTF8, oversized and non-object JSON',
    () {
      for (final bytes in [
        utf8.encode('<html>secret</html>'),
        [255],
        utf8.encode('[]'),
        List.filled(4 * 1024 * 1024 + 1, 32),
      ]) {
        expect(
          () => decodeAddressBookSnapshotResponse(200, {
            'Content-Type': 'application/json',
          }, bytes),
          fails('invalid_response'),
        );
      }
      expect(
        () => decodeAddressBookSnapshotResponse(200, {
          'Content-Type': 'text/html',
        }, utf8.encode('{}')),
        fails('invalid_response'),
      );
      expect(
        () => decodeAddressBookSnapshotResponse(403, {}, utf8.encode('secret')),
        fails('http_403'),
      );
      expect(
        decodeAddressBookSnapshotResponse(200, {
          'Content-Type': 'application/json; charset=utf-8',
        }, utf8.encode(jsonEncode(metadata()))),
        metadata(),
      );
    },
  );

  test('read deadline terminates one attempt and never retries', () async {
    var calls = 0;
    final pending = Completer<Map<String, dynamic>>();
    await expectLater(
      AddressBookContentSnapshot.read(
        apiBase: Uri.parse('https://management.invalid'),
        guid: guid,
        budget: const Duration(milliseconds: 10),
        request: (_) {
          calls++;
          return pending.future;
        },
      ),
      fails('deadline'),
    );
    pending.complete(page(1, 0, []));
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
  });
}
