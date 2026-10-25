'use strict';
const assert = require('node:assert/strict');
const { createScope, runProbe } = require('./dart-contract-probe.cjs');
if (process.argv.length !== 2) throw new Error('Usage: node test-http-browser.cjs');
const scope = createScope();
scope.CAMELLIA_HTTP_STREAM_READY = false;
const observed = new Map();
scope.fetch = async (url, init) => {
  const scenario = new URL(url).pathname;
  assert.equal(init.redirect, 'error');
  assert.equal(init.method, 'POST');
  assert(init.signal instanceof AbortSignal);
  assert(!observed.has(scenario), 'A scenario was retried');
  const state = { aborted: false, readerCancelled: false };
  observed.set(scenario, state);
  init.signal.addEventListener('abort', () => { state.aborted = true; });
  if (scenario === '/success') {
    assert.equal(new TextDecoder().decode(init.body), '{"note":"原生😀"}');
    return new Response('{"note":"原生😀"}', { headers: { 'Content-Type': 'application/json' } });
  }
  if (scenario === '/stalled-headers') {
    return new Promise((resolve, reject) => {
      init.signal.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true });
    });
  }
  if (scenario !== '/stalled-body' && scenario !== '/oversize') throw new Error('Unexpected scenario');
  let done = false;
  const stream = new ReadableStream({
    start(controller) {
      init.signal.addEventListener('abort', () => {
        if (!done) { done = true; controller.error(new DOMException('Aborted', 'AbortError')); }
      });
      if (scenario === '/oversize') controller.enqueue(new Uint8Array(1024 * 1024 + 1));
      else scope.CAMELLIA_HTTP_STREAM_READY = true;
    },
    cancel() { done = true; state.readerCancelled = true; },
  });
  return new Response(stream, { headers: { 'Content-Type': 'application/json' } });
};
const watchdog = setTimeout(() => { console.error('Browser HTTP probe deadline'); process.exit(1); }, 10000);
(async () => {
  runProbe('http', scope);
  await scope.CAMELLIA_HTTP_PROBE;
  assert.equal(observed.size, 4);
  assert.equal(observed.get('/stalled-headers').aborted, true);
  assert.equal(observed.get('/stalled-body').aborted, true);
  assert.equal(observed.get('/oversize').readerCancelled, true);
  clearTimeout(watchdog);
  console.log('Compiled BrowserClient: UTF-8 bytes, no redirect/retry, header/body cancellation and oversized reader cleanup passed (fetch substitutes).');
})().catch(() => {
  clearTimeout(watchdog);
  console.error('Compiled BrowserClient HTTP probe failed');
  process.exitCode = 1;
});
