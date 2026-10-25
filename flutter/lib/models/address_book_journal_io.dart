import 'address_book_journal_native.dart';
import 'address_book_mutations.dart';
import 'platform_model.dart';

AddressBookMutationJournal createAddressBookMutationJournal() =>
    NativeAddressBookMutationJournal(bind.mainManagementOperationJournal);
