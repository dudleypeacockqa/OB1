import test from 'node:test';
import assert from 'node:assert/strict';
import { createSupabaseStore } from '../src/supabase.js';
const scope = { projectId: 'fixture-a', workstream: 'review' };
const jwt = (patch = {}) => ['header', Buffer.from(JSON.stringify({ sub: 'fixture-user', role: 'authenticated', exp: Math.floor(Date.now()/1000)+300, ...patch })).toString('base64url'), 'signature'].join('.');
function build(options = {}) {
  const calls = [];
  const store = createSupabaseStore({ projectRef: 'abcdefghijklmnopqrst', publishableKey: 'sb_publishable_fixture', session: async () => jwt(), fetchImpl: async (url, init) => { calls.push({url,init}); return { ok:true, status:200, text:async () => JSON.stringify({ value:1 }) }; }, ...options });
  return { store, calls };
}
test('RPC adapter uses exact Supabase origin, user bearer and supplied scope', async () => {
  const h = build();
  await h.store.preflight({...scope, eventId:'event', payloadHash:'hash'});
  await h.store.commit({...scope, content:'reviewed'});
  await h.store.fetch({...scope, id:'id'});
  await h.store.search({...scope, queryVector:[1]});
  await h.store.list({...scope, limit:3});
  assert.equal(h.calls.length,5);
  for (const c of h.calls) { assert.match(c.url,/^https:\/\/abcdefghijklmnopqrst\.supabase\.co\/rest\/v1\/rpc\/ob1_scoped_/); assert.equal(JSON.parse(c.init.body).p_request.projectId,scope.projectId); assert.match(c.init.headers.Authorization,/^Bearer /); assert.ok(c.init.signal); }
});
test('invalid origins and session sources are refused', () => {
  for (const projectRef of ['', 'evil.com/a', 'A'.repeat(20)]) assert.throws(() => build({projectRef}),/CONFIGURATION_DENIED/);
  assert.throws(() => build({session:null}), /CONFIGURATION_DENIED/);
});
test('missing, expired, malformed and privileged tokens never reach the network', async () => {
  for (const token of [null,'not-a-token',jwt({role:'service_role'}),jwt({exp:0}),jwt({sub:''})]) {
    const h=build({session:async()=>token}); await assert.rejects(h.store.list(scope),/AUTH_REQUIRED/); assert.equal(h.calls.length,0);
  }
});
test('transport and response failures are bounded and sanitised', async () => {
  for (const response of [{ok:false,status:403,text:async()=> 'private'}, {ok:false,status:500,text:async()=> 'private'}, {ok:true,status:200,text:async()=> 'invalid'}, {ok:true,status:200,text:async()=> 'x'.repeat(300000)}]) {
    const h=build({fetchImpl:async()=>response}); await assert.rejects(h.store.list(scope),/PROJECT_FORBIDDEN|STORE_UNAVAILABLE/);
  }
  const h=build({fetchImpl:async()=>{throw new Error('private token');}}); await assert.rejects(h.store.list(scope),/^Error: STORE_UNAVAILABLE$/);
});
