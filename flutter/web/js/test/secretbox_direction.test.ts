import assert from 'node:assert/strict';
import test from 'node:test';
import nacl from 'tweetnacl';
import {
  CryptoError,
  SecretBoxCipher,
  createSymmetricKey,
  decodeSymmetricKey
} from '../src/runtime/crypto.ts';

function xor(left: Uint8Array, right: Uint8Array): number[] {
  assert.equal(left.length, right.length);
  return Array.from(left, (value, index) => value ^ right[index]);
}

test('opposite directions never reuse the SecretBox keystream', () => {
  const key = new Uint8Array(32).fill(0x5a);
  const clientPlaintext = new TextEncoder().encode('known client request');
  const serverPlaintext = new TextEncoder().encode('secret server reply!');
  const client = new SecretBoxCipher(key, 'initiator');
  const server = new SecretBoxCipher(key, 'responder');

  const clientCiphertext = client.encrypt(clientPlaintext);
  const serverCiphertext = server.encrypt(serverPlaintext);

  assert.notDeepEqual(
    xor(clientCiphertext.slice(16), serverCiphertext.slice(16)),
    xor(clientPlaintext, serverPlaintext),
    'opposite directions reused the SecretBox keystream'
  );
});

test('opposite roles decrypt both directions', () => {
  const key = new Uint8Array(32).fill(0x3c);
  const initiator = new SecretBoxCipher(key, 'initiator');
  const responder = new SecretBoxCipher(key, 'responder');
  const request = new TextEncoder().encode('request');
  const response = new TextEncoder().encode('response');

  assert.deepEqual(responder.decrypt(initiator.encrypt(request)), request);
  assert.deepEqual(initiator.decrypt(responder.encrypt(response)), response);
});

test('same roles and legacy nonces fail authentication without consuming sequence', () => {
  const key = new Uint8Array(32).fill(0x7d);
  const initiator = new SecretBoxCipher(key, 'initiator');
  const wrongRole = new SecretBoxCipher(key, 'initiator');
  const payload = new TextEncoder().encode('role-bound payload');
  const ciphertext = initiator.encrypt(payload);

  assert.throws(() => wrongRole.decrypt(ciphertext), CryptoError);

  const responder = new SecretBoxCipher(key, 'responder');
  const tampered = ciphertext.slice();
  tampered[0] ^= 0x80;
  assert.throws(() => responder.decrypt(tampered), CryptoError);
  assert.deepEqual(responder.decrypt(ciphertext), payload);

  const legacyNonce = new Uint8Array(nacl.secretbox.nonceLength);
  legacyNonce[0] = 1;
  const legacyCiphertext = nacl.secretbox(payload, legacyNonce, key);
  const freshResponder = new SecretBoxCipher(key, 'responder');
  assert.throws(() => freshResponder.decrypt(legacyCiphertext), CryptoError);
});

test('short frames and sequence exhaustion fail closed', () => {
  const key = new Uint8Array(32).fill(0x41);
  const cipher = new SecretBoxCipher(key, 'initiator');
  for (let length = 0; length < nacl.secretbox.overheadLength; length += 1) {
    assert.throws(() => cipher.decrypt(new Uint8Array(length)), CryptoError);
  }

  const internals = cipher as unknown as {
    sendSeq: readonly [number, number];
    recvSeq: readonly [number, number];
  };
  internals.sendSeq = [0xffffffff, 0xffffffff];
  internals.recvSeq = [0xffffffff, 0xffffffff];
  assert.throws(() => cipher.encrypt(new Uint8Array()), /send sequence exhausted/i);
  assert.throws(
    () => cipher.decrypt(new Uint8Array(nacl.secretbox.overheadLength)),
    /receive sequence exhausted/i
  );
});

test('session-key envelope is versioned and rejects the legacy format', () => {
  const responder = nacl.box.keyPair();
  const generated = createSymmetricKey(responder.publicKey);
  assert.deepEqual(
    decodeSymmetricKey(
      generated.sealed,
      generated.publicKey,
      responder.secretKey
    ),
    generated.symmetricKey
  );

  const nonce = new Uint8Array(nacl.box.nonceLength);
  const legacySender = nacl.box.keyPair();
  const sealedLegacy = nacl.box(
    generated.symmetricKey,
    nonce,
    responder.publicKey,
    legacySender.secretKey
  );
  assert.throws(
    () => decodeSymmetricKey(sealedLegacy, legacySender.publicKey, responder.secretKey),
    /envelope length/i
  );
});
