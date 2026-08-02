import 'package:camellia_remote_app/models/peer_model.dart';
import 'package:camellia_remote_app/models/platform_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('peer collections expose deterministic first-load state', () async {
    final peers = Peers(
      name: 'test recent peers',
      loadEvent: 'test_load_recent_peers',
      getInitPeers: null,
    );
    addTearDown(peers.dispose);

    var notifications = 0;
    peers.addListener(() => notifications += 1);

    expect(peers.hasLoaded, isFalse);
    expect(peers.isLoading, isFalse);
    peers.beginLoad();
    expect(peers.isLoading, isTrue);
    expect(notifications, 1);

    peers.beginLoad();
    expect(notifications, 1, reason: 'duplicate loads must not flicker the UI');

    await platformFFI.tryHandle({
      'name': 'test_load_recent_peers',
      'peers': '',
    });
    expect(peers.hasLoaded, isTrue);
    expect(peers.isLoading, isFalse);
    expect(notifications, 2);
  });
}
