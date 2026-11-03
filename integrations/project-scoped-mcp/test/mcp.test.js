import test from 'node:test';
import assert from 'node:assert/strict';
import { createMcpHandler } from '../src/mcp.js';
test('MCP lifecycle, tool schemas and call boundaries', async () => {
  const connector={capture:async p=>p, search:async p=>[p], fetch:async p=>p, list:async p=>[p]};
  const handle=createMcpHandler(connector);
  assert.equal(await handle({jsonrpc:'2.0',method:'notifications/initialized'}),null);
  const init=await handle({jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2024-11-05'}}); assert.equal(init.result.protocolVersion,'2024-11-05');
  const tools=await handle({jsonrpc:'2.0',id:2,method:'tools/list'}); assert.equal(tools.result.tools.length,4);
  for (const name of ['capture_thought','search_thoughts','fetch','list_thoughts']) {
    const r=await handle({jsonrpc:'2.0',id:3,method:'tools/call',params:{name,arguments:{query:'fixture'}}}); assert.equal(r.result.isError,false);
  }
  connector.search=async()=>{throw new Error('private stack');};
  const err=await handle({jsonrpc:'2.0',id:4,method:'tools/call',params:{name:'search_thoughts',arguments:{}}}); assert.equal(err.result.isError,true); assert.doesNotMatch(JSON.stringify(err),/private stack/);
});
test('invalid protocol, method and tool return structured errors',async()=>{
  const h=createMcpHandler({});
  for (const msg of [null,{}, {id:1,method:'tools/list'}, {jsonrpc:'2.0',id:1,method:'missing'}, {jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'missing'}}, {jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'future'}}]) assert.ok((await h(msg)).error);
  assert.deepEqual((await h({jsonrpc:'2.0',id:1,method:'ping'})).result,{});
});
