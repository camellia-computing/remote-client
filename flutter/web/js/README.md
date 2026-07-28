# Web Client JS Bridge

This folder hosts the JavaScript/TypeScript bridge that the Flutter web client
calls via `window.getByName` and `window.setByName`.

## Commands

```bash
npm ci
npm run lint
npm run build
```

The build outputs `dist/web_bridge.js` plus hashed lazy chunks, which are loaded
by `flutter/web/index.html`. The build also rejects stale protobuf codecs and
any bundle or configured software decoder that needs CSP `unsafe-eval`.

## Protocol codecs

The canonical protocol definitions live in
`libs/camellia_remote_protocol/protos/{message,rendezvous}.proto`. The browser uses committed
static codecs from `src/proto/generated.js`; it does not construct protobuf
encoders with runtime code generation.

After either canonical protocol file changes, regenerate the browser codecs:

```bash
npm run generate:proto
```

The generator downloads the exact `protobufjs-cli@2.6.1` release only for that
maintenance command. It is intentionally not a project dependency because its
legacy CLI dependency graph has unresolved development-only advisories. A
source digest in the generated file makes normal builds fail if regeneration
was missed.

## Dev

```bash
npm run dev
```

Use this for quick iteration while keeping `flutter run -d chrome` in another
terminal.

## Runtime design

The web runtime is built in TypeScript under `web/js/src`. The `WebRuntime`
class exposes `setByName` and `getByName` for Flutter, manages session state,
and owns the browser protocol/transport implementation. Core boundaries:

- Keep browser glue isolated in `core/`.
- Put protocol and session logic in `runtime/`.
- Keep shared protocol definitions canonical in `libs/camellia_remote_protocol`.
- Load same-origin OGV decoder scripts directly so the strict Web CSP does not
  require `unsafe-eval`.
