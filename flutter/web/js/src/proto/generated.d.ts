type StaticProtoType = {
  encode(payload: unknown): { finish(): Uint8Array };
  decode(payload: Uint8Array): unknown;
  toObject(
    message: unknown,
    options?: Record<string, unknown>
  ): Record<string, unknown>;
};

export const hbb: {
  IdPk: StaticProtoType;
  Message: StaticProtoType;
  RendezvousMessage: StaticProtoType;
};
