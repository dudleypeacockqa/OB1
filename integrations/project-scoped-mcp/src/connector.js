import { createHash } from 'node:crypto';

const sha = value => createHash('sha256').update(value).digest('hex');
const fail = code => { throw new Error(code); };
const text = (value, max = 16000) => typeof value === 'string' && value.trim().length > 0 && value.length <= max;
const digest = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const limit = value => value === undefined ? 10 : Number.isInteger(value) && value > 0 && value <= 100 ? value : fail('INPUT_DENIED');

/** No model, network, credential loading or activation on import. Dependencies are trusted host code. */
export function createConnector({ scope, space, store, embedder, enabled = () => false }) {
  if (!scope || !text(scope.projectId, 100) || !text(scope.workstream, 200) || !space ||
      !text(space.id, 200) || space.dimensions !== 384 || !digest(space.digest) ||
      embedder?.approval?.host !== 'external' || embedder.approval.metered !== false ||
      !text(embedder.approval.reference, 500) || typeof embedder.embed !== 'function' ||
      !store || typeof enabled !== 'function') fail('CONFIGURATION_DENIED');
  const boundScope = Object.freeze({ ...scope });
  const boundSpace = Object.freeze({ ...space });
  const check = args => {
    if (enabled() !== true) fail('GATE_CLOSED');
    if (!args || typeof args !== 'object') fail('INPUT_DENIED');
    if ((args.projectId !== undefined && args.projectId !== boundScope.projectId) ||
        (args.workstream !== undefined && args.workstream !== boundScope.workstream)) fail('PROJECT_FORBIDDEN');
  };
  const validateRow = row => {
    if (!row || row.projectId !== boundScope.projectId || row.workstream !== boundScope.workstream ||
        row.spaceId !== boundSpace.id || row.reviewed !== true || !text(row.versionId) || !text(row.recordId) ||
        !text(row.content) || !digest(row.sourceHash) || row.contentHash !== sha(row.content) ||
        !text(row.knowledgeId) || !text(row.reviewId) || !text(row.sourceLocator) || row.spaceDigest !== boundSpace.digest) fail('READBACK_FAILED');
    // Do not emit vectors, tokens or arbitrary adapter fields into model context.
    const { recordId, versionId, knowledgeId, reviewId, content, contentHash, sourceHash, sourceLocator, supersedes = null } = row;
    return { ...boundScope, recordId, versionId, knowledgeId, reviewId, content, contentHash, sourceHash, sourceLocator, supersedes, spaceId: boundSpace.id, spaceDigest: boundSpace.digest, reviewed: true };
  };
  const embed = async content => {
    let result;
    try { result = await embedder.embed(content, boundSpace); } catch { fail('EMBEDDING_UNAVAILABLE'); }
    if (!result || result.spaceId !== boundSpace.id || result.digest !== boundSpace.digest || !Array.isArray(result.values) ||
        result.values.length !== boundSpace.dimensions || !result.values.every(Number.isFinite) ||
        !result.values.some(value => value !== 0) || !text(result.receiptId, 100)) fail('VECTOR_INVALID');
    return result;
  };
  const rows = result => { if (!Array.isArray(result)) fail('READBACK_FAILED'); return result.map(validateRow); };
  return Object.freeze({
    async capture(args) {
      check(args);
      if (![args.content, args.knowledgeId, args.eventId, args.sourceLocator, args.reviewId].every(value => text(value)) ||
          !digest(args.sourceHash) || args.sensitivity !== 'non_sensitive' ||
          !(args.recordId === undefined || text(args.recordId, 100)) ||
          !(args.expectedVersion === null || text(args.expectedVersion, 100)) ||
          /-----BEGIN .*PRIVATE KEY-----/.test(args.content)) fail('INPUT_DENIED');
      const p = { ...boundScope, content: args.content, recordId: args.recordId ?? null, knowledgeId: args.knowledgeId, eventId: args.eventId,
        sourceHash: args.sourceHash, sourceLocator: args.sourceLocator, reviewId: args.reviewId,
        expectedVersion: args.expectedVersion, sensitivity: args.sensitivity,
        contentHash: sha(args.content), spaceId: boundSpace.id, spaceDigest: boundSpace.digest };
      p.payloadHash = sha(JSON.stringify(p));
      const prior = await store.preflight(p);
      let outcome;
      if (prior?.duplicate === true) outcome = prior;
      else if (prior?.duplicate === false) {
        const embedding = await embed(p.content);
        outcome = await store.commit({ ...p, embedding: embedding.values, embeddingReceiptId: embedding.receiptId });
      }
      else fail('READBACK_FAILED');
      if (typeof outcome?.duplicate !== 'boolean') fail('READBACK_FAILED');
      const matchesRequest = row => ['contentHash','sourceHash','sourceLocator','knowledgeId','reviewId','spaceDigest'].every(key => row[key] === p[key]) && row.supersedes === p.expectedVersion && (p.recordId === null || row.recordId === p.recordId);
      const expected = validateRow(outcome.version);
      if (!matchesRequest(expected)) fail('READBACK_FAILED');
      const read = validateRow(await store.fetch({ ...boundScope, id: expected.recordId, versionId: expected.versionId }));
      if (read.recordId !== expected.recordId || read.versionId !== expected.versionId || !matchesRequest(read)) fail('READBACK_FAILED');
      return { ...read, duplicate: outcome.duplicate };
    },
    async search(args) {
      check(args); if (!text(args.query)) fail('INPUT_DENIED');
      const count = limit(args.limit);
      return rows(await store.search({ ...boundScope, spaceId: boundSpace.id, queryVector: (await embed(args.query)).values, limit: count }));
    },
    async fetch(args) {
      check(args); if (!text(args.id, 100)) fail('INPUT_DENIED');
      const row = validateRow(await store.fetch({ ...boundScope, id: args.id }));
      if (row.recordId !== args.id) fail('READBACK_FAILED');
      return row;
    },
    async list(args) {
      check(args); return rows(await store.list({ ...boundScope, spaceId: boundSpace.id, limit: limit(args.limit) }));
    },
  });
}
