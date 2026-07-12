# @cairn/web

PowerSync-style JS facade over the `cairn-ffi-wasm` apply engine.

**Status: reduced-scope feasibility proof.** Loads the wasm in Node 22+ and drives the in-memory apply engine (`CairnEngine`, `Frame`, `Outcome`). Does NOT yet open a live WebSocket — see "Ceiling" below.

## Build

```sh
# from sdk/cairn_web (or repo root with -p)
npm run build
# → invokes: wasm-pack build ../../crates/cairn-ffi-wasm --target nodejs --out-dir pkg-node
```

The build writes to `crates/cairn-ffi-wasm/pkg-node/` (gitignored). The facade resolves that path relative to itself, so any cwd works.

## Smoke

```sh
node smoke.cjs
```

Exercises `connect`, `subscribe`, `write`, `query`, `watch` against the in-memory engine.

## API (PowerSync-shaped)

| method | behavior |
|---|---|
| `new CairnClient({ url, token, table })` | construct (no I/O) |
| `connect()` | `Promise<this>` — reduced-scope: marks ready, does not open WS |
| `subscribe(table, whereSql)` | stores the predicate on the engine |
| `write(table, pk, payload)` | feeds an insert Frame, flushes, returns `{ checkpoint, rowsApplied }` |
| `query(table)` | reads the rows currently held via `rowsFor` |
| `watch(table, cb)` | fires `cb` once with a snapshot, returns an unsubscribe stub |
| `checkpoint` / `rowCount` | getters on the engine |

## Ceiling (ponytail)

`CairnSocket.connect()` — the live browser WS transport (E1) — is wired to `web-sys::WebSocket` + `Window::localStorage`, which node lacks. This package intentionally does not call it. Upgrade paths:

1. **Node WS adapter** — a thin Rust module that replaces the web-sys transport at the `CairnSocket` seam, gated behind `#[cfg(feature = "node-transport")]`.
2. **Browser build** — `wasm-pack build --target web` + a bundler (vite/webpack) where WebSocket + localStorage are native. A vitest browser-env test replaces this node smoke.

## What this proves

Cairn's wasm apply engine loads and runs in Node 22 via `require()`, with a PowerSync-shaped JS surface on top — moving Cairn from 3/10 to 5/10 platform coverage.
