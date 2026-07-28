type ProtoTypeLike = {
  encode(payload: unknown): { finish(): Uint8Array };
  decode(payload: Uint8Array): unknown;
  toObject(
    message: unknown,
    options?: Record<string, unknown>
  ): Record<string, unknown>;
};

export type ProtoRoots = {
  messageType: ProtoTypeLike;
  rendezvousType: ProtoTypeLike;
  idPkType: ProtoTypeLike;
};

type DecodedWithToObject = {
  toObject?: (options?: Record<string, unknown>) => Record<string, unknown>;
};

export async function loadProtos(): Promise<ProtoRoots> {
  const { hbb } = await import('../proto/generated.js');
  return {
    messageType: hbb.Message,
    rendezvousType: hbb.RendezvousMessage,
    idPkType: hbb.IdPk
  };
}

export function decodeProtoObject<T extends Record<string, unknown>>(
  type: ProtoTypeLike,
  data: Uint8Array,
  options?: Record<string, unknown>
): T {
  const decoded = type.decode(data) as DecodedWithToObject;
  if (typeof decoded.toObject === 'function') {
    return decoded.toObject(options) as T;
  }
  return type.toObject(decoded, options) as T;
}
