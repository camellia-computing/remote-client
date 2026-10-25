import 'package:camellia_remote_app/models/ab_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'shared profile credential parser accepts only a non-empty 200 password',
    () {
      expect(
        parseSharedCredentialResponse('{"password":"target-secret"}', 200),
        'target-secret',
      );
      expect(parseSharedCredentialResponse('{"password":""}', 200), isNull);
      expect(
        parseSharedCredentialResponse(
          '{"password":"${List.filled(61, 'x').join()}"}',
          200,
        ),
        isNull,
      );
      expect(
        parseSharedCredentialResponse('{"password":"target-secret"}', 404),
        isNull,
      );
      expect(
        parseSharedCredentialResponse('{"error":"not found"}', 200),
        isNull,
      );
      expect(parseSharedCredentialResponse('not-json', 200), isNull);
      expect(parseSharedCredentialResponse('["target-secret"]', 200), isNull);
    },
  );
}
