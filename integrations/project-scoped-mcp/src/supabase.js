/** Authenticated REST RPC adapter. Session signature and membership are verified by Supabase, not by local decoding. */
export function createSupabaseStore({ projectRef, publishableKey, session, fetchImpl = globalThis.fetch }) {
  if (!/^[a-z]{20}$/.test(projectRef) || typeof publishableKey !== 'string' || !publishableKey.startsWith('sb_publishable_') || typeof session !== 'function' || typeof fetchImpl !== 'function') throw new Error('CONFIGURATION_DENIED');
  const origin = `https://${projectRef}.supabase.co/rest/v1/rpc/`;
  async function rpc(name, request) {
    let token; let claims;
    try { token = await session(); claims = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()); } catch { throw new Error('AUTH_REQUIRED'); }
    // Reject accidental privileged tokens; this is not a JWT signature verifier.
    if (claims.role !== 'authenticated' || !claims.sub || !Number.isFinite(claims.exp) || claims.exp <= Date.now()/1000) throw new Error('AUTH_REQUIRED');
    let response; let body;
    try {
      response = await fetchImpl(`${origin}${name}`, { method: 'POST', redirect: 'error',
        headers: { Authorization: `Bearer ${token}`, apikey: publishableKey, 'Content-Type': 'application/json' },
        body: JSON.stringify({ p_request: request }), signal: AbortSignal.timeout(15000) });
      if (!response.ok) throw new Error(response.status === 403 ? 'PROJECT_FORBIDDEN' : 'STORE_UNAVAILABLE');
      body = await response.text(); if (body.length > 262144) throw new Error('STORE_UNAVAILABLE');
      return JSON.parse(body);
    } catch (error) { throw new Error(error.message === 'PROJECT_FORBIDDEN' ? 'PROJECT_FORBIDDEN' : 'STORE_UNAVAILABLE'); }
  }
  return Object.freeze({
    preflight: request => rpc('ob1_scoped_preflight', request),
    commit: request => rpc('ob1_scoped_commit', request),
    fetch: request => rpc('ob1_scoped_fetch', request),
    search: request => rpc('ob1_scoped_search', request),
    list: request => rpc('ob1_scoped_list', request),
  });
}
