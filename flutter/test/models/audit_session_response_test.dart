import 'package:flutter_test/flutter_test.dart';
import 'package:camellia_remote_app/models/model.dart';

void main() {
  test('accepts only canonical v2 audit session capabilities', () {
    const capability = '123e4567-e89b-42d3-a456-426614174000';
    expect(
      auditSessionCapabilityFromResponseBody(
        '{"version":2,"audit_session_id":"$capability","revision":3}',
      ),
      capability,
    );

    for (final body in <String>[
      '{"version":1,"audit_session_id":"$capability","revision":3}',
      '{"version":2,"audit_session_id":"$capability","revision":0}',
      '{"version":2,"audit_session_id":"00000000-0000-0000-0000-000000000000","revision":3}',
      '{"error":"Connection is closed"}',
      'not-json',
    ]) {
      expect(auditSessionCapabilityFromResponseBody(body), isEmpty);
    }
  });
}
