import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createConnector } from '../src/connector.js';

const hash = text => createHash('sha256').update(text).digest('hex');
const scope = { projectId: '00000000-0000-4000-8000-000000000001', workstream: 'fixture-a' };
const space = { id: 'fixture-space-v1', dimensions: 384, digest: 'a'.repeat(64) };
const vector = [1, ...Array(383).fill(0)];
const input = () => ({ content: 'A work item retains its project and parent link.', knowledgeId: 'fixture-source/section-1', eventId: 'event-1', sourceHash: hash('source'), sourceLocator: 'fixture/section-1', reviewId: '00000000-0000-4000-8000-000000000002', expectedVersion: null, sensitivity: 'non_sensitive' });
function harness(overrides = {}) {
  const versions = new Map(); const events = new Map(); let current; let embeddings = 0;
  const store = {
    async preflight(p) {
      const old = events.get(p.eventId);
      if (old && old.payloadHash !== p.payloadHash) throw new Error('EVENT_CONFLICT');
      return old ? { duplicate: true, version: versions.get(old.versionId) } : { duplicate: false };
    },
    async commit(p) {
      if ((current?.versionId ?? null) !== p.expectedVersion) throw new Error('STALE_VERSION');
      const row = { ...p, recordId: 'record-1', versionId: `version-${versions.size + 1}`, reviewed: true, supersedes: current?.versionId ?? null };
      versions.set(row.versionId, row); events.set(p.eventId, { payloadHash: p.payloadHash, versionId: row.versionId }); current = row; return row;
    },
    async fetch(p) { return p.versionId ? versions.get(p.versionId) : current; },
    async search() { return current ? [current] : []; },
    async list() { return current ? [current] : []; },
  };
  const embedder = { approval: { reference: 'fixture-only', host: 'external', metered: false }, async embed() { embeddings++; return { spaceId: space.id, digest: space.digest, receiptId: 'fixture-receipt', values: vector }; } };
  const connector = createConnector({ scope, space, store, embedder, enabled: () => true, ...overrides });
  return { connector, store, embedder, versions, events, count: () => embeddings };
}

test('capture stores complete reviewed provenance and read-back; retry is a no-op before embedding', async () => {
  const h = harness(); const p = input();
  const first = await h.connector.capture(p);
  const replay = await h.connector.capture(p);
  assert.equal(first.versionId, replay.versionId); assert.equal(replay.duplicate, true);
  assert.equal(h.count(), 1); assert.equal(h.versions.size, 1);
  assert.equal(first.contentHash, hash(p.content)); assert.equal(first.sourceHash, p.sourceHash);
});
test('immutable version update preserves history and rejects stale writes', async () => {
  const h = harness(); const first = await h.connector.capture(input());
  const next = await h.connector.capture({ ...input(), content: 'A revised reviewed fixture.', eventId: 'event-2', expectedVersion: first.versionId });
  assert.equal(next.supersedes, first.versionId); assert.equal(h.versions.get(first.versionId).content, input().content);
  assert.equal((await h.connector.search({ query: 'How is a task linked?' }))[0].versionId, next.versionId);
  await assert.rejects(h.connector.capture({ ...input(), eventId: 'event-3' }), /STALE_VERSION/);
});
test('event key cannot be reused for changed content', async () => {
  const h = harness(); await h.connector.capture(input());
  await assert.rejects(h.connector.capture({ ...input(), content: 'Different text' }), /EVENT_CONFLICT/);
  assert.equal(h.count(), 1);
});
test('required scope and external non-metered approval fail closed', () => {
  for (const options of [{ scope: {} }, { scope: null }, { space: {} }, { embedder: { approval: { host: 'workstation', metered: false } } }, { embedder: { approval: { host: 'external', metered: true } } }, { embedder: {} }]) {
    assert.throws(() => harness(options), /CONFIGURATION_DENIED/);
  }
});
test('closed activation gate blocks every operation', async () => {
  const h = harness({ enabled: () => false });
  for (const run of [() => h.connector.capture(input()), () => h.connector.search({ query: 'q' }), () => h.connector.fetch({ id: 'x' }), () => h.connector.list({})]) await assert.rejects(run(), /GATE_CLOSED/);
  assert.equal(h.count(), 0);
});
test('default activation gate is closed', async () => {
  const h = harness({ enabled: undefined }); await assert.rejects(h.connector.search({ query: 'q' }), /GATE_CLOSED/);
});
test('forged scope is rejected before model or database activity', async () => {
  const h = harness();
  for (const args of [{ projectId: 'other' }, { workstream: 'other' }]) {
    await assert.rejects(h.connector.capture({ ...input(), ...args }), /PROJECT_FORBIDDEN/);
    await assert.rejects(h.connector.search({ query: 'q', ...args }), /PROJECT_FORBIDDEN/);
    await assert.rejects(h.connector.fetch({ id: 'x', ...args }), /PROJECT_FORBIDDEN/);
    await assert.rejects(h.connector.list(args), /PROJECT_FORBIDDEN/);
  }
  assert.equal(h.count(), 0);
});
test('capture input rejects missing review, invalid source and private material', async () => {
  const h = harness();
  for (const patch of [{ content: '' }, { sourceHash: 'wrong' }, { reviewId: '' }, { sourceLocator: '' }, { eventId: '' }, { knowledgeId: '' }, { sensitivity: 'private' }, { content: '-----BEGIN PRIVATE KEY-----' }, { content: 'x'.repeat(16001) }, { expectedVersion: 2 }]) await assert.rejects(h.connector.capture({ ...input(), ...patch }), /INPUT_DENIED/);
  assert.equal(h.count(), 0);
});
test('embedding space, length, finiteness and norm are verified', async () => {
  for (const result of [null, { spaceId: 'other', digest: space.digest, values: vector }, { spaceId: space.id, digest: 'b'.repeat(64), values: vector }, { spaceId: space.id, digest: space.digest, values: [1] }, { spaceId: space.id, digest: space.digest, values: Array(384).fill(0) }, { spaceId: space.id, digest: space.digest, values: [NaN, ...vector.slice(1)] }]) {
    const h = harness(); h.embedder.embed = async () => result;
    await assert.rejects(h.connector.capture(input()), /VECTOR_INVALID/); assert.equal(h.versions.size, 0);
  }
});
test('provider failure is sanitised and cannot fall back', async () => {
  const h = harness(); h.embedder.embed = async () => { throw new Error('private provider response'); };
  await assert.rejects(h.connector.search({ query: 'q' }), /^Error: EMBEDDING_UNAVAILABLE$/);
  assert.equal(h.versions.size, 0);
});
test('read-back and database return boundaries reject untrusted records', async () => {
  for (const patch of [{ projectId: 'other' }, { workstream: 'other' }, { spaceId: 'other' }, { reviewed: false }, { contentHash: 'wrong' }, { content: 'tampered' }, { sourceHash: 'bad' }]) {
    const h = harness(); const original = h.store.fetch;
    h.store.fetch = async p => ({ ...await original(p), ...patch });
    await assert.rejects(h.connector.capture(input()), /READBACK_FAILED/);
  }
  const h = harness(); h.store.fetch = async () => null;
  await assert.rejects(h.connector.capture(input()), /READBACK_FAILED/);
});
test('duplicate read-back must match requested source/content, not just ID', async () => {
  const h = harness(); const first = await h.connector.capture(input());
  h.store.preflight = async () => ({ duplicate: true, version: { ...first, sourceHash: hash('other') } });
  await assert.rejects(h.connector.capture(input()), /READBACK_FAILED/);
});
test('fetch/list/search return only validated current scoped data', async () => {
  const h = harness(); const row = await h.connector.capture(input());
  assert.equal((await h.connector.fetch({ id: row.recordId })).versionId, row.versionId);
  assert.equal((await h.connector.list({ limit: 2 }))[0].recordId, row.recordId);
  assert.equal((await h.connector.search({ query: 'parent ownership', limit: 2 }))[0].recordId, row.recordId);
  h.store.search = async () => [{ ...row, projectId: 'b' }];
  await assert.rejects(h.connector.search({ query: 'q' }), /READBACK_FAILED/);
  h.store.list = async () => null; await assert.rejects(h.connector.list({}), /READBACK_FAILED/);
});
test('query, ID and limit bounds reject malformed requests', async () => {
  const h = harness();
  for (const query of ['', 2, 'x'.repeat(16001)]) await assert.rejects(h.connector.search({ query }), /INPUT_DENIED/);
  for (const limit of [0, 101, 1.5, '2']) await assert.rejects(h.connector.list({ limit }), /INPUT_DENIED/);
  await assert.rejects(h.connector.fetch({ id: '' }), /INPUT_DENIED/);
});
