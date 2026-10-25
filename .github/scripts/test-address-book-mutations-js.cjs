'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { createScope, runProbe } = require('./dart-contract-probe.cjs');

if (process.argv.length !== 2) {
  throw new Error('Usage: node test-address-book-mutations-js.cjs');
}
const scope = createScope();
scope.CAMELLIA_MUTATION_VECTORS = fs.readFileSync(
  path.resolve(__dirname, '../../flutter/test/fixtures/address_book_mutations_v1.json'), 'utf8',
);
scope.CAMELLIA_MUTATION_PROBE_OK = false;
runProbe('mutations', scope);
if (scope.CAMELLIA_MUTATION_PROBE_OK !== true) {
  throw new Error('Compiled Dart protocol probe did not finish successfully');
}
console.log('Compiled Dart/JS: 7 canonical digest vectors, UUIDv4, If-Match and receipt integer boundaries passed.');
