const DEVICE_UUID_BYTES = 32;

function secureRandomBytes(length: number): Uint8Array {
  const cryptoApi = globalThis.crypto;
  if (!cryptoApi?.getRandomValues) {
    throw new Error('A secure browser context with Web Crypto is required');
  }
  return cryptoApi.getRandomValues(new Uint8Array(length));
}

export function generateUuid(): string {
  const cryptoApi = globalThis.crypto;
  if (cryptoApi?.randomUUID) {
    return cryptoApi.randomUUID();
  }
  const bytes = secureRandomBytes(16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = Array.from(bytes, (value) => value.toString(16).padStart(2, '0'));
  return [
    hex.slice(0, 4).join(''),
    hex.slice(4, 6).join(''),
    hex.slice(6, 8).join(''),
    hex.slice(8, 10).join(''),
    hex.slice(10).join('')
  ].join('-');
}

export function generateDeviceUuid(): string {
  const bytes = secureRandomBytes(DEVICE_UUID_BYTES);
  let binary = '';
  for (const value of bytes) {
    binary += String.fromCharCode(value);
  }
  return btoa(binary);
}

export function isCanonicalDeviceUuid(value: string): boolean {
  if (!value || value.length > 344) {
    return false;
  }
  try {
    const binary = atob(value);
    if (!binary || binary.length > 256) {
      return false;
    }
    return btoa(binary) === value;
  } catch {
    return false;
  }
}
