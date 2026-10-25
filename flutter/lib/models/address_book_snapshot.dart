/// The editable version belongs to a complete peers + tags snapshot, not a
/// catalog row or a single successful page. No Flutter/plugin state is used here.
library;

import 'dart:async';
import 'dart:convert';

class AddressBookSnapshotException implements Exception {
  final String code;
  const AddressBookSnapshotException(this.code);

  @override
  String toString() => 'Address book snapshot: $code';
}

class AddressBookSnapshotIdentity {
  final String guid;
  final int generation;

  const AddressBookSnapshotIdentity(this.guid, this.generation);

  factory AddressBookSnapshotIdentity.parse(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['address_book_snapshot_version'] is! int ||
        value['address_book_snapshot_version'] != 1) {
      throw const AddressBookSnapshotException('unsupported_version');
    }
    final guid = value['guid'];
    final generation = value['authorization_generation'];
    if (guid is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,60}$').hasMatch(guid) ||
        generation is! int ||
        generation < 0 ||
        // JavaScript must not round a version and then send a different If-Match.
        generation > 9007199254740991) {
      throw const AddressBookSnapshotException('invalid_identity');
    }
    return AddressBookSnapshotIdentity(guid, generation);
  }

  void requireSame(AddressBookSnapshotIdentity other) {
    if (guid != other.guid || generation != other.generation) {
      throw const AddressBookSnapshotException('snapshot_changed');
    }
  }
}

typedef AddressBookSnapshotRead =
    Future<Map<String, dynamic>> Function(Uri uri);

Map<String, dynamic> decodeAddressBookSnapshotResponse(
  int status,
  Map<String, String> headers,
  List<int> bytes,
) {
  if (status != 200) {
    throw AddressBookSnapshotException('http_$status');
  }
  final media = headers.entries
      .where((entry) => entry.key.toLowerCase() == 'content-type')
      .map((entry) => entry.value.toLowerCase().trim());
  if (media.length != 1 ||
      !RegExp(
        r'^application/json(?:;\s*charset=(?:utf-8|"utf-8"))?$',
      ).hasMatch(media.single) ||
      bytes.length > 4 * 1024 * 1024) {
    throw const AddressBookSnapshotException('invalid_response');
  }
  try {
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is Map<String, dynamic> &&
        decoded['response_schema_version'] is int &&
        decoded['response_schema_version'] == 1 &&
        !decoded.containsKey('error')) {
      return decoded;
    }
  } on FormatException {
    // Never expose HTML, response bodies, credentials or raw parser errors.
  }
  throw const AddressBookSnapshotException('invalid_response');
}

class AddressBookContentSnapshot {
  final AddressBookSnapshotIdentity identity;
  final List<Map<String, dynamic>> peers;
  final List<Map<String, dynamic>> tags;

  AddressBookContentSnapshot._(this.identity, this.peers, this.tags);

  /// One bounded attempt. Mixed/partial pages are discarded; never retry with
  /// a newer generation behind an editor's back.
  static Future<AddressBookContentSnapshot> read({
    required Uri apiBase,
    required String guid,
    required AddressBookSnapshotRead request,
    Duration budget = const Duration(seconds: 30),
  }) async {
    if (budget <= Duration.zero) {
      throw const AddressBookSnapshotException('deadline');
    }
    final watch = Stopwatch()..start();
    Future<Map<String, dynamic>> get(
      String path, [
      Map<String, String>? query,
    ]) async {
      final remaining = budget - watch.elapsed;
      if (remaining <= Duration.zero) {
        throw const AddressBookSnapshotException('deadline');
      }
      try {
        return await request(
          apiBase.replace(path: path, queryParameters: query),
        ).timeout(remaining);
      } on TimeoutException {
        throw const AddressBookSnapshotException('deadline');
      }
    }

    AddressBookSnapshotIdentity? identity;
    int? total;
    final peers = <Map<String, dynamic>>[];
    final peerIds = <String>{};
    const pageSize = 100;
    var current = 0;
    do {
      current++;
      final page = await get('${apiBase.path}/api/ab/peers', {
        'ab': guid,
        'current': '$current',
        'pageSize': '$pageSize',
      });
      final observed = AddressBookSnapshotIdentity.parse(page);
      if (observed.guid != guid) {
        throw const AddressBookSnapshotException('wrong_profile');
      }
      identity?.requireSame(observed);
      identity ??= observed;
      final count = page['total'];
      final data = page['data'];
      if (page['pagination_contract_version'] is! int ||
          page['pagination_contract_version'] != 1 ||
          page['current'] is! int ||
          page['pageSize'] is! int ||
          page['current'] != current ||
          page['pageSize'] != pageSize ||
          count is! int ||
          count < 0 ||
          count > 10000 ||
          (total != null && total != count) ||
          data is! List) {
        throw const AddressBookSnapshotException('invalid_page');
      }
      total = count;
      final expected = (total - peers.length).clamp(0, pageSize);
      if (data.length != expected) {
        throw const AddressBookSnapshotException('incomplete_page');
      }
      for (final peer in data) {
        if (peer is! Map<String, dynamic> ||
            peer['id'] is! String ||
            (peer['id'] as String).trim().isEmpty ||
            !peerIds.add(peer['id'] as String)) {
          throw const AddressBookSnapshotException('invalid_peer');
        }
        peers.add(Map.unmodifiable(peer));
      }
    } while (peers.length < total);

    final tagPage = await get('${apiBase.path}/api/ab/tags/$guid');
    identity.requireSame(AddressBookSnapshotIdentity.parse(tagPage));
    final data = tagPage['data'];
    if (data is! List ||
        data.length > 256 ||
        tagPage['total'] is! int ||
        tagPage['total'] != data.length) {
      throw const AddressBookSnapshotException('invalid_tags');
    }
    final tags = <Map<String, dynamic>>[];
    final names = <String>{};
    for (final tag in data) {
      if (tag is! Map<String, dynamic> ||
          tag['name'] is! String ||
          (tag['name'] as String).trim().isEmpty ||
          tag['color'] is! int ||
          (tag['color'] as int) < 0 ||
          (tag['color'] as int) > 0xffffffff ||
          !names.add(tag['name'] as String)) {
        throw const AddressBookSnapshotException('invalid_tag');
      }
      tags.add(Map.unmodifiable(tag));
    }
    return AddressBookContentSnapshot._(
      identity,
      List.unmodifiable(peers),
      List.unmodifiable(tags),
    );
  }
}
