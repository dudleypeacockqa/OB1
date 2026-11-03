const properties = {
  content: { type: 'string' }, query: { type: 'string' }, id: { type: 'string' },
  knowledgeId: { type: 'string' }, eventId: { type: 'string' }, sourceHash: { type: 'string' },
  sourceLocator: { type: 'string' }, reviewId: { type: 'string' },
  expectedVersion: { type: ['string', 'null'] }, sensitivity: { const: 'non_sensitive' },
  limit: { type: 'integer', minimum: 1, maximum: 100 },
};
const specs = [
  ['capture_thought', 'capture', ['content','knowledgeId','eventId','sourceHash','sourceLocator','reviewId','expectedVersion','sensitivity']],
  ['search_thoughts', 'search', ['query']], ['fetch', 'fetch', ['id']], ['list_thoughts', 'list', []],
];
/** Transport-neutral MCP request handler; no listener, credentials or provider are started here. */
export function createMcpHandler(connector) {
  return async message => {
    const id = message?.id ?? null;
    const error = (code, text) => ({ jsonrpc: '2.0', id, error: { code, message: text } });
    const result = value => ({ jsonrpc: '2.0', id, result: value });
    if (!message || message.jsonrpc !== '2.0' || typeof message.method !== 'string') return error(-32600, 'Invalid request');
    if (message.method === 'notifications/initialized' && message.id === undefined) return null;
    if (message.method === 'initialize') {
      if (!['2024-11-05','2025-03-26','2025-06-18'].includes(message.params?.protocolVersion)) return error(-32602, 'Unsupported protocol');
      return result({ protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: 'open-brain-scoped', version: '0.1.0' } });
    }
    if (message.method === 'ping') return result({});
    if (message.method === 'tools/list') return result({ tools: specs.map(([name, , required]) => ({ name,
      description: 'Reviewed project-scoped OB1 operation. Scope and embedding approval are bound by the host.',
      inputSchema: { type: 'object', properties, required, additionalProperties: false } })) });
    if (message.method !== 'tools/call') return error(-32601, 'Method not found');
    const spec = specs.find(([name]) => name === message.params?.name);
    if (!spec) return error(-32602, 'Unknown tool');
    try {
      const value = await connector[spec[1]](message.params.arguments ?? {});
      return result({ content: [{ type: 'text', text: JSON.stringify(value) }], isError: false });
    } catch {
      return result({ content: [{ type: 'text', text: 'Scoped operation failed; inspect the authorised operator receipt.' }], isError: true });
    }
  };
}
