import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cross-book copy excludes secrets, local options and unknown server flag',
    () {
      final peer = Peer.fromJson({
        'id': '123',
        'hash': 'private-hash',
        'password': 'private-password',
        'rdpPort': '3389',
        'rdpUsername': 'private-local-user',
        'forceAlwaysRelay': 'true',
        'tags': ['team'],
        'note': 'note',
      });
      final payload = peer.toAddressBookCopyJson();
      expect(payload.keys.toSet(), {
        'id',
        'username',
        'hostname',
        'platform',
        'alias',
        'tags',
        'loginName',
        'device_group_name',
        'note',
      });
      expect(payload['note'], 'note');
      (payload['tags'] as List).clear();
      expect(peer.tags, ['team']);
      peer.sameServer = false;
      expect(peer.toAddressBookCopyJson()['same_server'], false);
      peer.sameServer = true;
      expect(peer.toAddressBookCopyJson()['same_server'], true);
    },
  );

  test(
    'recent-session patch never mutates visible content before confirmation',
    () {
      final peer = Peer.fromJson({
        'id': '123',
        'username': 'old',
        'hash': 'old-hash',
      });
      final recent = Peer.fromJson({
        'id': '123',
        'username': 'new',
        'hostname': 'host',
        'platform': 'Linux',
        'hash': 'new-hash',
        'password': 'secret',
      });
      final before = peer.toJson();
      expect(peer.addressBookRecentPatch(recent, personal: true), {
        'id': '123',
        'username': 'new',
        'hostname': 'host',
        'platform': 'Linux',
        'hash': 'new-hash',
      });
      expect(peer.toJson(), before);
      expect(
        peer
            .addressBookRecentPatch(recent, personal: false)
            ?.containsKey('hash'),
        false,
      );
      peer.sameServer = true;
      expect(peer.addressBookRecentPatch(recent, personal: false), isNull);
      expect(peer.addressBookRecentPatch(recent, personal: true), {
        'id': '123',
        'hash': 'new-hash',
      });
      expect(peer.username, 'old');
      expect(peer.hash, 'old-hash');
    },
  );

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
