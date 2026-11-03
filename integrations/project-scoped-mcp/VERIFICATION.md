# Engineering verification and activation boundary

## Requirements and scenarios

This additive integration implements a reviewed project-scoped contract; no matching BMAD intent folder exists in this contribution. The source authority is OB1's `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING.md` and the owning requirement to retain Supabase while injecting an externally approved embedding interface. Existing Agent Memory API and core schema remain unchanged.

| Requirement | Executed fixture coverage |
| --- | --- |
| Deny missing/forged principal or project scope | Connector and RPC adapter unit tests; SQL cross-project and anonymous checks |
| No metered fallback or workstation model | No embedding implementation or model dependency; injected external-only approval contract; default closed gate |
| Same event is a no-op | Preflight duplicate and payload-conflict unit tests; transactional SQL replay |
| Preserve immutable source versions | Unit supersession/stale-write tests; SQL old/current/history checks |
| Reject mixed or invented vectors | Unit model digest/space/dimension/finite checks; database protected receipt check |
| Store then read back | Connector checks content/source/model/scope against fetched version; absent/mismatched read-back fails |
| Complete lineage and commit receipt | Same-hash source-locator/knowledge/review swaps and wrong record ID are rejected; concurrent preflight misses use authoritative commit replay flags |
| Keep legacy corpus intact | Schema adds only prefixed objects; no legacy table/RPC/queue write path |

Given a reviewed fixture in project A, when the event is replayed, the original version is returned before another embedding request. Given an A-only principal, when a known project B ID is requested, the database denies access. Given a newer accepted version, current search returns it and authorised history retains the old version.

## Commands

Run `npm test` and `npm run lint` here. `npm audit --offline --audit-level=high` checks the dependency-free lock without installing packages. The dedicated CI workflow executes the same tests on Node.js 22 and runs the SQL fixtures against a digest-pinned ephemeral PostgreSQL/pgvector image. Existing OB1 mechanical and Markdown checks still apply.

The database tests run only in disposable CI storage, with fake identities and administratively seeded synthetic vector receipts. They are not production migrations, real authentication tests or semantic paraphrase evidence. Unit coverage includes all new JavaScript source files. SQL behaviour is covered by the database fixture, not included in JavaScript coverage percentages.

The concurrency unit fixture deliberately lets both callers miss preflight, requires one stable stored version and flags `[false, true]`, and records two embedding requests. That is an explicit boundary: preflight is an optimisation, not an exactly-once external embedding lock. SQL fixtures independently verify that creation and replay return authoritative false/true receipts with the complete rendered lineage.

## Remaining release gates

Independent maintainer/security review, exact-head CI and source approval are required before merge. An approved remote embedding host must provide a real model manifest and protected receipt registration route. No Azure/AWS account, runtime, model, network policy or cost authority is established here. No local model exception is implied.

Remote MCP transport/authentication, native trust, Supabase schema/reviewer/space/principal provisioning, backup/restore evidence and genuine source-backed paraphrase retrieval remain gated. A provider response, fabricated vector, unit mock or green ephemeral SQL job cannot close these live acceptance gates.

Rollback disables only the new approved connector and preserves additive receipts/versions. It never invokes the old paid capture/search route or removes the legacy corpus. No destructive down migration is included.
