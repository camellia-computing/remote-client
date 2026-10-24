'use strict';

const fs = require('node:fs');
const path = require('node:path');

if (process.argv.length !== 3) {
  throw new Error('Usage: node test-address-book-mutations-js.cjs COMPILED_DART_JS');
}
globalThis.self = globalThis;
globalThis.crypto ??= require('node:crypto').webcrypto;
globalThis.CAMELLIA_MUTATION_VECTORS = fs.readFileSync(
  path.resolve(__dirname, '../../flutter/test/fixtures/address_book_mutations_v1.json'), 'utf8',
);
globalThis.CAMELLIA_MUTATION_PROBE_OK = false;
require(path.resolve(process.argv[2]));
if (globalThis.CAMELLIA_MUTATION_PROBE_OK !== true) {
  throw new Error('Compiled Dart protocol probe did not finish successfully');
}
console.log('Compiled Dart/JS: 7 canonical digest vectors, UUIDv4, If-Match and receipt integer boundaries passed.');
