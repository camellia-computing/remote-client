import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'address_book_mutations.dart';

/// Canonical, checksummed browser metadata; no payload, credentials or digest of
/// a password-bearing request is ever accepted by this encoder.
String encodeAddressBookJournal(List<PendingAddressBookOperation> pending) {
  if (pending.length > 1) {
    throw const AddressBookMutationException('journal_corrupt');
  }
  final document = {
    'journal_version': 1,
    'pending': pending.map((record) => record.toJson()).toList(),
  };
  final checksum = sha256.convert(utf8.encode(jsonEncode(document))).toString();
  return jsonEncode({...document, 'checksum': checksum});
}

List<PendingAddressBookOperation> decodeAddressBookJournal(String? text) {
  if (text == null) return const [];
  if (text.length > 4096) {
    throw const AddressBookMutationException('journal_corrupt');
  }
  try {
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 3 ||
        decoded['journal_version'] is! int ||
        decoded['journal_version'] != 1 ||
        decoded['pending'] is! List ||
        (decoded['pending'] as List).length > 1) {
      throw const AddressBookMutationException('journal_corrupt');
    }
    final pending = (decoded['pending'] as List)
        .map(PendingAddressBookOperation.fromJson)
        .toList();
    // Exact canonical comparison also rejects duplicate fields, imprecise
    // numbers, alternate encodings and ambiguous corrupt metadata.
    if (encodeAddressBookJournal(pending) != text) {
      throw const AddressBookMutationException('journal_corrupt');
    }
    return List.unmodifiable(pending);
  } catch (_) {
    throw const AddressBookMutationException('journal_corrupt');
  }
}
