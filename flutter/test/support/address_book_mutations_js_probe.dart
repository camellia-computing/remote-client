/// Compile with dart2js and execute via the repository Node runner. This proves
/// protocol arithmetic/UTF-8/digests on JS, not browser persistence or HTTP.
library;

import 'dart:convert';
import 'dart:js_interop';

import 'package:camellia_remote_app/models/address_book_mutations.dart';

@JS('CAMELLIA_MUTATION_VECTORS')
external JSString get _vectors;
@JS('CAMELLIA_MUTATION_PROBE_OK')
external set _succeeded(JSBoolean value);

void check(bool value, String code) {
  if (!value) throw StateError(code);
}

void main() {
  final corpus = jsonDecode(_vectors.toDart);
  check(corpus['version'] == 1, 'fixture_version');
  for (final vector in corpus['vectors']) {
    check(
      addressBookRequestDigest(
            operation: vector['operation'],
            method: vector['method'],
            path: vector['path'],
            body: vector['body'],
            expectedGeneration: vector['expected_generation'],
          ) ==
          vector['request_digest'],
      'digest_mismatch',
    );
  }
  final request = AddressBookMutationCommand(
    kind: AddressBookMutationKind.tagUpdate,
    apiBase: Uri.parse('https://management.invalid'),
    guid: 'personal-7',
    expectedGeneration: 9007199254740990,
    payload: {'name': '团队😀', 'color': 0xffffffff},
  );
  check(
    request.headers('test-token')['If-Match'] == '"9007199254740990"',
    'if_match_precision',
  );
  final receipt = AddressBookMutationReceipt.verify(
    request,
    AddressBookMutationResponse(
      200,
      {'content-type': 'application/json'},
      utf8.encode(
        jsonEncode({
          'response_schema_version': 1,
          'management_operation_receipt_version': 1,
          'operation': request.kind.operation,
          'operation_id': request.operationId,
          'request_digest': request.requestDigest,
          'result_digest': List.filled(64, 'b').join(),
          'operation_generation': 1,
          'requested': {'mutations': 1},
          'applied': {'mutations': 1},
          'result': 'OK',
          'mutation_generation': 9007199254740991,
          'mutation_generations': {'personal-7': 9007199254740991},
        }),
      ),
    ),
  );
  check(receipt.generation == 9007199254740991, 'receipt_precision');
  var rejected = false;
  try {
    AddressBookMutationCommand(
      kind: AddressBookMutationKind.peerDelete,
      apiBase: Uri.parse('https://management.invalid'),
      guid: 'personal-7',
      expectedGeneration: 9007199254740992,
      payload: ['123'],
    );
  } on AddressBookMutationException {
    rejected = true;
  }
  check(rejected, 'unsafe_integer_accepted');
  _succeeded = true.toJS;
}
