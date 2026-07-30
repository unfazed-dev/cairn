# ADR-0023: The `.cairn/` project directory and pluggable backend adapters

- **Status:** **Accepted (shipped)** — corrected 2026-07-30, it said "Proposed" after shipping.
  As built: `DOT_CAIRN_DIR` / `.cairn/config.json` / `.cairn/schema.json` in
  `crates/cairn-cli/src/config.rs:178`, written by `cairn link` and `cairn pull`, plus all seven
  subcommands (`init`, `link`, `pull`, `gen`, `dev`, `doctor`, `deploy`).
- **Date:** 2026-07-14
- **Related:** ADR-0001 (hexagonal ports), ADR-0007 (Supabase assembly), ADR-0019 (schema-as-views), ADR-0021 (schema discovery REST)

## Context

Today the Flutter example configures cairn via `assets/cairn.json` plus a hand-written
`CairnSchema` in Dart. This has three problems:

1. **No single onboarding artifact.** The dev has no obvious "this is where cairn lives
   in my repo" location; config is buried in a Flutter-specific `assets/` convention.
2. **Multi-SDK divergence.** Flutter, React Native (ADR-0020), and Web/Node SDKs would
   each invent their own config/schema carrier. Schema declared in Dart cannot be reused
   by a TS SDK.
3. **Backend coupling.** `CairnConfig` hardcodes a `supabase` block. v1 targets Supabase
   (ADR-0007) but cairn must also run against plain Postgres and, later, Appwrite and
   other backends. The coupling must live behind an adapter seam, not in every SDK's
   config parser.

Ecosystem survey (what devs already know):

| Tool | Convention | Lesson |
|---|---|---|
| Supabase CLI | `supabase/` dir: committed `config.toml` + `migrations/`, gitignored `.temp/` | Committed declarative config, gitignored local state |
| Amplify Gen 2 | `amplify/` (resource code) → generated `amplify_outputs.json` consumed by every platform SDK | One neutral generated artifact feeds all SDKs |
| Prisma | `prisma/schema.prisma` = single schema file, codegen to client | Schema is a repo artifact, client is generated |
| FlutterFire | `flutterfire configure` emits `lib/firebase_options.dart` | Mobile runtimes can't read repo dirs — embed via codegen, not assets |
| Expo | `.expo/` fully gitignored (local state only) | Dot-dirs signal "tool-owned" |
| PowerSync | client `PowerSyncBackendConnector` (fetchCredentials/uploadData) | Backend specifics live behind a small connector interface |

## Decision

### D1 — `.cairn/` is the tool-owned project directory (all SDKs)

`cairn init` (CLI) scaffolds it at the host app repo root:

```
.cairn/
├── config.json     # COMMITTED  — project config incl. backend block (below)
├── schema.json     # COMMITTED  — SchemaDescriptor JSON (same wire format as GET /schema, ADR-0021)
└── local/          # GITIGNORED — secrets & tool state (service keys, cached LSN, logs)
```

- `schema.json` is **pulled, not authored**: `cairn pull` fetches the live descriptor
  from the server (which reads the Postgres catalog). The dev's source of truth remains
  their database, per the schema-strategy decision (server → schema → model, never
  model → schema).
- `cairn init` appends `.cairn/local/` to `.gitignore`.
- The cairn server dev loop (`cairn dev`) reads the same `.cairn/config.json`, so app
  and server share one config surface.

### D2 — Runtime embedding via codegen, never via assets

Mobile bundles cannot read repo directories at runtime (the reason FlutterFire generates
`firebase_options.dart`). `cairn gen` reads `.cairn/` and emits idiomatic source per SDK:

- Flutter → `lib/cairn.g.dart`: `CairnConfig` const, `CairnSchema` const, typed
  `CairnModel` subclasses with `fromRow`/`toPayload`.
- TS (Web/Node/RN) → `src/cairn.g.ts` equivalents.

`assets/cairn.json` + `CairnConfig.load()` remain as the low-level runtime carrier the
generated code sits on top of (or is bypassed by), but stop being the documented
entry point.

### D3 — CLI verbs

Split by audience — operator (runs the server) vs app (ships the client):

| Verb | Audience | Effect |
|---|---|---|
| `cairn init` | operator | Connect to Postgres, create the publication, write `cairn.toml` + `.env` (unchanged; `dev`/`doctor`/`deploy` depend on it) |
| `cairn dev`  | operator | Run the local server from `cairn.toml` + `.env` |
| `cairn link` | **app** | Scaffold `.cairn/` at the app repo root, detect backend, write `.cairn/config.json` + gitignore `.cairn/local/` |
| `cairn pull` | **app** | `GET {http_base}/schema` → `.cairn/schema.json` |
| `cairn gen`  | **app** | `.cairn/` → per-SDK generated source (config + schema + typed models) |

`cairn init` (operator: publication + `cairn.toml`) and `cairn link` (app:
`.cairn/config.json`) write different artifacts to different directories and do
not collide. This split **supersedes the first draft of D3**, which overloaded
`init` for app scaffolding and would have broken the working operator flow.

### D4 — Backend decoupling: a `backend` discriminated union + server-side adapter port

`config.json`:

```jsonc
{
  "project": "provider-dashboard",
  "sync_url": "ws://127.0.0.1:8800/sync",
  "backend": { "kind": "supabase", "url": "https://xyz.supabase.co", "anon_key": "…" }
  // or { "kind": "postgres" }            — pure Postgres, no platform auth
  // or { "kind": "appwrite", "endpoint": "…", "project_id": "…" }  (post-v1)
}
```

Server side this lands on the **existing hexagonal ports** (ADR-0001): a backend is an
assembly of already-defined ports — change source (`ReplicatorStream`), snapshot
(`SnapshotSource`), schema (`PgSchemaSource`), write-back (`PgWriteBack`), and auth
(`JwtVerifier`). A `BackendAdapter` is a named preset wiring of those ports:

- `postgres` — logical replication + no platform auth (bring-your-own JWT / none in dev).
- `supabase` — the `postgres` adapter + Supabase JWKS `JwtVerifier` + anon-key client
  conventions. **Supabase is a preset, not a fork.** (ADR-0007 unchanged: it stays the
  v1 assembly.)
- `appwrite` (later) — Appwrite does **not** expose Postgres logical replication, so its
  adapter implements the change-source port over Appwrite's realtime/events API and the
  write-back port over its REST API. The port seam is exactly where that difference is
  absorbed; SDKs and `.cairn/` are unaffected.

Client SDKs never branch on backend kind beyond auth credential acquisition (mirroring
PowerSync's connector split): the generated config carries a `backend` block the SDK's
auth module consumes; sync protocol code is backend-agnostic.

## Consequences

- Onboarding becomes: `pub add cairn_flutter` → `cairn init` → `cairn pull && cairn gen`
  → open db with generated schema. No hand-written schema, no assets wiring.
- `schema.json` (SchemaDescriptor) becomes the cross-SDK contract; ADR-0021's wire
  format gains a second consumer and must be versioned (`descriptor_version` field).
- A new `cairn` CLI surface must be built and versioned alongside the server.
- Existing example app migrates from `assets/cairn.json` + hand-written `_appSchema`
  to `.cairn/` + `cairn.g.dart` (follow-up work item).
- Appwrite support is scoped OUT of v1 but the port seam and config union prevent any
  v1 decision from blocking it.
