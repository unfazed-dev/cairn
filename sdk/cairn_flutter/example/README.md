# cairn_flutter example — offline-first tasks demo

A Flutter app demonstrating the `cairn_flutter` SDK: subscribe to a Postgres
table, render rows reactively, and write offline-first (instant-local + oplog
sync with reconcile on echo).

The app connects to `ws://127.0.0.1:8800/sync` by default
(`--dart-define=CAIRN_URL=...` to override) and persists to a temp SQLite file.

## Run it (local Postgres)

Two terminals:

```sh
# Terminal 1 — start cairn-server against a real Postgres (Docker).
# `make dev-stack` composes PG, waits for the `cairn_pub` publication, then runs
# cairn-server with CAIRN_REPLICATOR=pg + CAIRN_PG_URL set.
make dev-stack

# Terminal 2 — run the Flutter app (from this example/ dir).
flutter run
```

The app auto-fetches the server's typed schema (`GET /schema`) and materializes
read-views, so `tasks` rows render with real columns (`title`, `completed`, …).

## Run it (Supabase / cloud Postgres)

See `docs/plans/cairn-reference-demo-app.md` for the full cloud-backed launch
(relays cairn-server to Supabase over WARP). The server must be launched with:

```sh
CAIRN_BIND=127.0.0.1:8800 \
CAIRN_REPLICATOR=pg \
CAIRN_PG_URL='postgresql://postgres:<pw>@127.0.0.1:15433/postgres?sslmode=disable' \
CAIRN_PG_SLOT=cairn_slot CAIRN_PG_PUBLICATION=cairn_pub \
RUST_LOG=info ./target/debug/cairn-server
```

(build the binary with `--features pg`.)

## ⚠️ Do NOT use `make run` for this demo

`make run` starts cairn-server with the **`fake`** replicator (no Postgres).
With the fake replicator:

- Writes are **not** replicated (`ok:false` → dead-lettered) — "add a task does
  nothing." (Write-back requires `CAIRN_REPLICATOR=pg`.)
- Rows render as **raw bytes**, not typed columns (the fake replicator emits
  filler, not JSON).
- The server logs a warning: *"CAIRN_PG_URL is set but CAIRN_REPLICATOR is not
  'pg' — snapshot-on-subscribe is OFF; clients will not receive pre-existing
  rows on connect."*

Always use `make dev-stack` (local) or the `CAIRN_REPLICATOR=pg` launch block
above (cloud). If you see only one row in the app with five in Postgres, you are
in fake mode — stop the server and relaunch with `CAIRN_REPLICATOR=pg`.
