'use strict';

const path = require('node:path');
const assert = require('node:assert/strict');
if (process.argv.length !== 3) {
  throw new Error('Usage: node test-address-book-journal-web.cjs COMPILED_DART_JS');
}
globalThis.self = globalThis;
globalThis.window = globalThis;
globalThis.crypto ??= require('node:crypto').webcrypto;
globalThis.CAMELLIA_JOURNAL_FAULT = '';
const storage = new Map();
let held = false;
const localStorage = {
  getItem(key) { return storage.has(key) ? storage.get(key) : null; },
  setItem(key, value) {
    if (globalThis.CAMELLIA_JOURNAL_FAULT === 'quota') throw new Error('STORAGE-SECRET');
    if (globalThis.CAMELLIA_JOURNAL_FAULT !== 'readback') storage.set(key, value);
  },
};
globalThis.localStorage = localStorage;
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { locks: {
  request(name, options, callback) {
    assert.equal(name, 'camellia-address-book-operations-v1-lock');
    assert.equal(options.mode, 'exclusive');
    assert.equal(options.ifAvailable, true);
    if (globalThis.CAMELLIA_JOURNAL_FAULT === 'locks') throw new Error('LOCK-SECRET');
    if (held) return Promise.resolve(callback(null));
    held = true;
    try { return Promise.resolve(callback({ name })).finally(() => { held = false; }); }
    catch (error) { held = false; return Promise.reject(error); }
  },
} } });
const watchdog = setTimeout(() => { console.error('Web journal probe deadline'); process.exit(1); }, 10000);
(async () => {
  require(path.resolve(process.argv[2]));
  await globalThis.CAMELLIA_JOURNAL_PROBE;
  clearTimeout(watchdog);
  console.log('Compiled Dart web journal: reload, concurrent admission, exact ACK, quota, corruption and missing-lock failures passed (DOM/lock substitutes).');
})().catch(() => {
  clearTimeout(watchdog);
  console.error('Compiled Dart web journal probe failed');
  process.exitCode = 1;
});
