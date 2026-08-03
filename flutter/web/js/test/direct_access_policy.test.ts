import assert from 'node:assert/strict';
import test from 'node:test';
import {
  assertPeerAuthenticatedRoute,
  isDirectAccessTarget
} from '../src/runtime/direct_access_policy.ts';

const directTargets = [
  '192.0.2.1',
  '192.0.2.1:21118',
  'remote.example.com:21118',
  '[2001:db8::1]',
  '[2001:db8::1]:21118',
  'ws://192.0.2.1:21118',
  'wss://remote.example.com/direct'
];

test('direct targets fail closed before any unauthenticated transport opens', () => {
  for (const target of directTargets) {
    assert.equal(isDirectAccessTarget(target), true, target);
    assert.throws(
      () => assertPeerAuthenticatedRoute(target),
      /peer-authenticated encrypted direct protocol/i,
      target
    );
  }
});

test('numeric device IDs remain eligible for the authenticated rendezvous route', () => {
  for (const target of ['123456789', ' 123456789 ']) {
    assert.equal(isDirectAccessTarget(target), false, target);
    assert.doesNotThrow(() => assertPeerAuthenticatedRoute(target));
  }
});
