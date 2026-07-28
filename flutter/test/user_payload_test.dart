import 'package:camellia_remote_app/common/hbbs/hbbs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('current user cache retains account profile fields', () {
    final user = UserPayload.fromJson({
      'name': 'mira',
      'display_name': 'Mira Chen',
      'avatar': 'https://example.test/avatar.png',
      'email': 'mira@example.test',
      'note': 'Design team',
      'is_admin': true,
      'verifier': 'cached-verifier',
      'status': 1,
    });

    expect(user.toJson(), {
      'name': 'mira',
      'display_name': 'Mira Chen',
      'avatar': 'https://example.test/avatar.png',
      'email': 'mira@example.test',
      'note': 'Design team',
      'is_admin': true,
      'verifier': 'cached-verifier',
      'status': 1,
    });
  });
}
