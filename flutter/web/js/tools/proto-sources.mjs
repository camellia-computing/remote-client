import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const toolsDir = dirname(fileURLToPath(import.meta.url));

export const protoSources = [
  resolve(toolsDir, '../../../../libs/camellia_remote_protocol/protos/message.proto'),
  resolve(toolsDir, '../../../../libs/camellia_remote_protocol/protos/rendezvous.proto')
];

export async function protoSourceDigest() {
  const hash = createHash('sha256');
  for (const source of protoSources) {
    hash.update(source.split(/[\\/]/u).at(-1) ?? source);
    hash.update('\0');
    hash.update(await readFile(source));
    hash.update('\0');
  }
  return hash.digest('hex');
}
