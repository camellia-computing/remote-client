import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'address_book_journal_codec.dart';
import 'address_book_mutations.dart';

class WebAddressBookMutationJournal implements AddressBookMutationJournal {
  static const storageKey = 'camellia-address-book-operations-v1';
  static const lockName = 'camellia-address-book-operations-v1-lock';

  List<PendingAddressBookOperation> _read() =>
      decodeAddressBookJournal(web.window.localStorage.getItem(storageKey));
  void _write(List<PendingAddressBookOperation> pending) {
    final text = encodeAddressBookJournal(pending);
    web.window.localStorage.setItem(storageKey, text);
    if (web.window.localStorage.getItem(storageKey) != text) {
      throw const AddressBookMutationException('journal_unavailable');
    }
  }

  Future<List<PendingAddressBookOperation>> _locked(
    List<PendingAddressBookOperation> Function() operation,
  ) async {
    List<PendingAddressBookOperation>? result;
    String? errorCode;
    try {
      await web.window.navigator.locks
          .request(
            lockName,
            web.LockOptions(mode: 'exclusive', ifAvailable: true),
            ((JSAny? lock) {
              if (lock == null) {
                errorCode = 'journal_busy';
                return false.toJS;
              }
              try {
                result = operation();
              } catch (error) {
                errorCode =
                    error is AddressBookMutationException &&
                        const {
                          'journal_unavailable',
                          'journal_corrupt',
                          'journal_pending',
                          'journal_identity_conflict',
                        }.contains(error.code)
                    ? error.code
                    : 'journal_unavailable';
              }
              return (errorCode == null).toJS;
            }).toJS,
          )
          .toDart;
    } catch (_) {
      throw const AddressBookMutationException('journal_unavailable');
    }
    if (errorCode != null) throw AddressBookMutationException(errorCode!);
    if (result == null) {
      throw const AddressBookMutationException('journal_unavailable');
    }
    return result!;
  }

  @override
  Future<List<PendingAddressBookOperation>> readPending() => _locked(_read);

  @override
  Future<void> reserve(PendingAddressBookOperation operation) async {
    await _locked(() {
      if (_read().isNotEmpty) {
        throw const AddressBookMutationException('journal_pending');
      }
      _write([operation]);
      return [operation];
    });
  }

  @override
  Future<void> acknowledge(PendingAddressBookOperation operation) async {
    await _locked(() {
      final current = _read();
      if (current.isEmpty) return const [];
      if (!current.single.matches(operation)) {
        throw const AddressBookMutationException('journal_identity_conflict');
      }
      _write(const []);
      return const [];
    });
  }
}

AddressBookMutationJournal createAddressBookMutationJournal() =>
    WebAddressBookMutationJournal();
