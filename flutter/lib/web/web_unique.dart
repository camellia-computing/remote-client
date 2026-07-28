import 'dart:async';
import 'dart:convert';
import 'package:camellia_remote_app/web/js_interop_bridge.dart' as js;

Future<void> webselectFiles({required bool is_folder}) async {
  return Future(
      () => js.context.callMethod('setByName', ['select_files', is_folder]));
}

Future<void> webSendLocalFiles(
    {required int handleIndex,
    required int actId,
    required String path,
    required String to,
    required int fileNum,
    required bool includeHidden,
    required bool isRemote}) {
  return Future(() => js.context.callMethod('setByName', [
        'send_local_files',
        jsonEncode({
          'id': actId,
          'handle_index': handleIndex,
          'path': path,
          'to': to,
          'file_num': fileNum,
          'include_hidden': includeHidden,
          'is_remote': isRemote,
        })
      ]));
}

Future<void> webRegisterDroppedFiles(
    {required List<Map<String, dynamic>> files}) {
  return Future(() => js.context.callMethod('setByName', [
        'register_drop_files',
        jsonEncode({
          'files': files,
        })
      ]));
}
