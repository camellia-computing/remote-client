import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:camellia_remote_app/models/file_model.dart';

Future<SelectedItems> buildDroppedItems(List<XFile> files,
    {required bool isLocal}) async {
  final items = SelectedItems(isLocal: isLocal);
  for (final file in files) {
    final path = file.path;
    final isDirectory = await FileSystemEntity.isDirectory(path);
    var size = 0;
    if (!isDirectory) {
      try {
        size = await File(path).length();
      } catch (_) {
        size = await file.length();
      }
    }
    items.add(Entry()
      ..entryType = isDirectory ? 2 : 4
      ..path = path
      ..name = file.name
      ..size = size);
  }
  return items;
}
