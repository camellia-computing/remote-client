import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('address book peer response maps every displayed field', () {
    final peer = Peer.fromJson({
      'id': '765432100',
      'hash': 'personal-hash',
      'password': '',
      'username': 'mira',
      'hostname': 'studio-mac',
      'platform': 'Mac OS',
      'alias': 'Design workstation',
      'tags': ['studio', 'trusted'],
      'note': 'Primary workstation',
      'device_group_name': 'Design',
      'loginName': 'mira@example.test',
      'same_server': true,
    });

    expect(peer.id, '765432100');
    expect(peer.getId(), 'Design workstation');
    expect(peer.username, 'mira');
    expect(peer.hostname, 'studio-mac');
    expect(peer.platform, 'Mac OS');
    expect(peer.tags, ['studio', 'trusted']);
    expect(peer.note, 'Primary workstation');
    expect(peer.device_group_name, 'Design');
    expect(peer.loginName, 'mira@example.test');
    expect(peer.sameServer, isTrue);
  });
}
