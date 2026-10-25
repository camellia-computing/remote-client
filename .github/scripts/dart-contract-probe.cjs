'use strict';

// Compile only repository-owned probe entrypoints and execute them in an
// isolated browser scope. Never require/evaluate a filename from CLI input.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const { webcrypto } = require('node:crypto');

const entries = Object.freeze({
  mutations: 'address_book_mutations_js_probe.dart',
  journal: 'address_book_journal_web_probe.dart',
  http: 'http_browser_probe.dart',
});

function createScope() {
  return {
    console, crypto: webcrypto,
    setTimeout, clearTimeout, setInterval, clearInterval, queueMicrotask,
    URL, URLSearchParams, TextEncoder, TextDecoder,
    AbortController, AbortSignal, DOMException,
    ReadableStream, WritableStream, TransformStream, Headers, Request, Response,
    ArrayBuffer, SharedArrayBuffer, DataView,
    Uint8Array, Int8Array, Uint8ClampedArray, Uint16Array, Int16Array,
    Uint32Array, Int32Array, Float32Array, Float64Array, BigInt64Array, BigUint64Array,
  };
}

function runProbe(kind, scope) {
  if (!Object.hasOwn(entries, kind)) throw new Error('Unknown Dart contract probe');
  const flutterRoot = path.resolve(__dirname, '../../flutter');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'camellia-dart-contract-'));
  const compiled = path.join(directory, 'probe.js');
  try {
    execFileSync('dart', [
      'compile', 'js', '-O2',
      path.join(flutterRoot, 'test/support', entries[kind]), '-o', compiled,
    ], { cwd: flutterRoot, stdio: 'inherit', timeout: 30000, windowsHide: true });
    scope.self = scope;
    scope.window = scope;
    const context = vm.createContext(scope);
    vm.runInContext(fs.readFileSync(compiled, 'utf8'), context, {
      filename: `compiled-${kind}-probe.js`, timeout: 5000,
    });
    return context;
  } finally {
    // Only our private compiler directory. Preserve unexpected structures.
    const artifacts = fs.readdirSync(directory, { withFileTypes: true });
    if (artifacts.some(entry => !entry.isFile())) {
      throw new Error('Unexpected Dart compiler artifact type');
    }
    for (const entry of artifacts) fs.unlinkSync(path.join(directory, entry.name));
    fs.rmdirSync(directory);
  }
}

module.exports = { createScope, runProbe };
