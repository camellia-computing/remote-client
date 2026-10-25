import assert from 'node:assert/strict';
import test from 'node:test';
import nacl from 'tweetnacl';

import {
  deviceSigningPublicKey,
  encodeBase64,
  generateDeviceSigningKeyPair,
  signDeviceProof,
  validateDeviceProofChallenge
} from '../src/runtime/crypto.ts';


test('device proof uses a matching persistent Ed25519 identity', () => {
  const keyPair = generateDeviceSigningKeyPair();
  const publicKey = deviceSigningPublicKey(keyPair.secretKey);
  const message = 'camellia-device-proof-v1\noidc\nchallenge';
  const signature = signDeviceProof(message, keyPair.secretKey);

  assert.deepEqual(publicKey, keyPair.publicKey);
  assert.equal(
    nacl.sign.detached.verify(new TextEncoder().encode(message), signature, publicKey),
    true
  );
});

test('device proof rejects malformed secret keys', () => {
  assert.throws(() => deviceSigningPublicKey(new Uint8Array(32)));
  assert.throws(() => signDeviceProof('message', new Uint8Array(32)));
});

test('device proof challenge validation binds every canonical field', async () => {
  const keyPair = generateDeviceSigningKeyPair();
  const digest = new Uint8Array(
    await globalThis.crypto.subtle.digest('SHA-256', keyPair.publicKey)
  );
  const publicKeyHash = Array.from(digest, (byte) => byte.toString(16).padStart(2, '0')).join('');
  const now = 1_800_000_000;
  const expiresAt = now + 30;
  const uuid = encodeBase64(new TextEncoder().encode('device-uuid'));
  const message = [
    'camellia-device-proof-v1',
    'login',
    'challenge',
    '123456789',
    uuid,
    '7',
    publicKeyHash,
    String(expiresAt)
  ].join('\n');

  assert.equal(
    await validateDeviceProofChallenge(
      'challenge',
      message,
      expiresAt,
      'login',
      '123456789',
      uuid,
      keyPair.publicKey,
      now
    ),
    message
  );
  await assert.rejects(
    validateDeviceProofChallenge(
      'challenge',
      message.replace('\nlogin\n', '\ndeploy\n'),
      expiresAt,
      'login',
      '123456789',
      uuid,
      keyPair.publicKey,
      now
    )
  );
});
