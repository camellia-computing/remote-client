import 'package:cross_file/cross_file.dart';
import 'package:camellia_remote_app/models/file_model.dart';

Future<SelectedItems> buildDroppedItems(List<XFile> files,
    {required bool isLocal}) async {
  return SelectedItems(isLocal: isLocal);
}
