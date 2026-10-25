import 'dart:js_interop';
import 'dart:js_interop_unsafe';

class JsContext {
  const JsContext();

  JSObject get _context => globalContext;

  dynamic callMethod(String method, [List<Object?> args = const []]) {
    final jsArgs = args.map(_toJsAny).toList(growable: false);
    final result = _context.callMethodVarArgs<JSAny?>(method.toJS, jsArgs);
    return result.dartify();
  }

  dynamic operator [](String property) => _context[property]?.dartify();

  void operator []=(String property, Object? value) {
    _context[property] = _toJsAny(value);
  }

  JSAny? _toJsAny(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is JSAny) {
      return value;
    }
    return value.jsify();
  }
}

const context = JsContext();

@JS('getDeviceProof')
external JSPromise<JSString> _getDeviceProof(
  JSString purpose,
  JSString id,
  JSString uuid,
  JSString token,
);

Future<String> getDeviceProof(
  String purpose,
  String id,
  String uuid,
  String token,
) async {
  final result = await _getDeviceProof(
    purpose.toJS,
    id.toJS,
    uuid.toJS,
    token.toJS,
  ).toDart;
  return result.toDart;
}
