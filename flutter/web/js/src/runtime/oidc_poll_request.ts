export interface OidcPollRequest {
  url: string;
  init: RequestInit;
}

export function createOidcPollRequest(
  apiServer: string,
  code: string,
  id: string,
  uuid: string
): OidcPollRequest {
  return {
    url: `${apiServer}/api/oidc/auth-query`,
    init: {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ code, id, uuid })
    }
  };
}
