import 'dart:convert';

import 'address_book_mutations.dart';

typedef NativeAddressBookJournalCall =
    Future<String> Function({
      required String action,
      required String operationId,
      required String scope,
      required String createdAtMs,
    });

/// Binding is injected so the parser/ordering can be tested without an engine.
/// The production implementation is the native Rust journal, never local options.
class NativeAddressBookMutationJournal implements AddressBookMutationJournal {
  final NativeAddressBookJournalCall call;
  NativeAddressBookMutationJournal(this.call);
  static const _errors = {
    'journal_busy',
    'journal_unavailable',
    'journal_corrupt',
    'invalid_journal_record',
    'journal_pending',
    'journal_identity_conflict',
  };

  Future<List<PendingAddressBookOperation>> _invoke(
    String action, [
    PendingAddressBookOperation? record,
  ]) async {
    final String text;
    try {
      text = await call(
        action: action,
        operationId: record?.operationId ?? '',
        scope: record?.scope ?? '',
        createdAtMs: record?.createdAt.toString() ?? '',
      );
    } catch (_) {
      throw const AddressBookMutationException('journal_unavailable');
    }
    if (utf8.encode(text).length > 4096) {
      throw const AddressBookMutationException('journal_corrupt');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const AddressBookMutationException('journal_corrupt');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['journal_version'] is! int ||
        decoded['journal_version'] != 1 ||
        decoded['code'] is! String) {
      throw const AddressBookMutationException('journal_corrupt');
    }
    final code = decoded['code'] as String;
    if (code != 'ok') {
      if (decoded.length != 2 || !_errors.contains(code)) {
        throw const AddressBookMutationException('journal_corrupt');
      }
      throw AddressBookMutationException(code);
    }
    final entries = decoded['pending'];
    if (decoded.length != 3 || entries is! List || entries.length > 1) {
      throw const AddressBookMutationException('journal_corrupt');
    }
    try {
      return List.unmodifiable(
        entries.map(PendingAddressBookOperation.fromJson),
      );
    } on AddressBookMutationException {
      throw const AddressBookMutationException('journal_corrupt');
    }
  }

  @override
  Future<List<PendingAddressBookOperation>> readPending() => _invoke('pending');

  @override
  Future<void> reserve(PendingAddressBookOperation operation) async {
    final pending = await _invoke('reserve', operation);
    if (pending.length != 1 || !pending.single.matches(operation)) {
      throw const AddressBookMutationException('journal_corrupt');
    }
  }

  @override
  Future<void> acknowledge(PendingAddressBookOperation operation) async {
    if ((await _invoke('acknowledge', operation)).isNotEmpty) {
      throw const AddressBookMutationException('journal_corrupt');
    }
  }
}
