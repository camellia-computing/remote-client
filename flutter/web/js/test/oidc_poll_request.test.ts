import assert from 'node:assert/strict';
import test from 'node:test';

import { createOidcPollRequest } from '../src/runtime/oidc_poll_request.ts';

test('OIDC poll credentials are sent only in a POST JSON body', () => {
  const request = createOidcPollRequest(
    'https://management.example.test',
    'poll-code-canary',
    '123456789',
    'device-uuid-canary'
  );

  assert.equal(request.url, 'https://management.example.test/api/oidc/auth-query');
  assert.equal(new URL(request.url).search, '');
  assert.equal(request.init.method, 'POST');
  assert.deepEqual(request.init.headers, { 'Content-Type': 'application/json' });
  assert.deepEqual(JSON.parse(String(request.init.body)), {
    code: 'poll-code-canary',
    id: '123456789',
    uuid: 'device-uuid-canary'
  });
});
