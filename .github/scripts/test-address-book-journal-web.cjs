'use strict';

const assert = require('node:assert/strict');
const { createScope, runProbe } = require('./dart-contract-probe.cjs');
if (process.argv.length !== 2) {
  throw new Error('Usage: node test-address-book-journal-web.cjs');
}
const scope = createScope();
scope.CAMELLIA_JOURNAL_FAULT = '';
const storage = new Map();
let held = false;
const localStorage = {
  getItem(key) { return storage.has(key) ? storage.get(key) : null; },
  setItem(key, value) {
    if (scope.CAMELLIA_JOURNAL_FAULT === 'quota') throw new Error('STORAGE-SECRET');
    if (scope.CAMELLIA_JOURNAL_FAULT !== 'readback') storage.set(key, value);
  },
};
scope.localStorage = localStorage;
scope.navigator = { locks: {
  request(name, options, callback) {
    assert.equal(name, 'camellia-address-book-operations-v1-lock');
    assert.equal(options.mode, 'exclusive');
    assert.equal(options.ifAvailable, true);
    if (scope.CAMELLIA_JOURNAL_FAULT === 'locks') throw new Error('LOCK-SECRET');
    if (held) return Promise.resolve(callback(null));
    held = true;
    try { return Promise.resolve(callback({ name })).finally(() => { held = false; }); }
    catch (error) { held = false; return Promise.reject(error); }
  },
} };
const watchdog = setTimeout(() => { console.error('Web journal probe deadline'); process.exit(1); }, 10000);
(async () => {
  runProbe('journal', scope);
  await scope.CAMELLIA_JOURNAL_PROBE;
  clearTimeout(watchdog);
  console.log('Compiled Dart web journal: reload, concurrent admission, exact ACK, quota, corruption and missing-lock failures passed (DOM/lock substitutes).');
})().catch(() => {
  clearTimeout(watchdog);
  console.error('Compiled Dart web journal probe failed');
  process.exitCode = 1;
});
