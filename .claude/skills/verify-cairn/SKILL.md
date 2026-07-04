---
name: verify-cairn
description: Use when verifying any Cairn change end-to-end before declaring it done or committing — runs the tiered verification ladder (ci → e2e → bench → demo) matched to what the diff touched.
---

# Verify Cairn

Run the cheapest sufficient rung, escalate by what the diff touched:

1. **Always:** `make ci` — fmt-check + clippy (-D warnings) + workspace tests.
2. **Diff touches `crates/cairn-infra/src/replicator/` or feature `pg`:**
   `docker compose -f docker/docker-compose.yml up -d` (check that file for
   port/credentials), then
   `CAIRN_PG_URL=<url from compose> cargo test -p cairn-infra --features pg`.
   Tear down with `docker compose -f docker/docker-compose.yml down -v`.
3. **Diff touches fanout/router/transport/wire (hot path):**
   `make bench` — compare against benches/results/RESULTS.md; a >10% regression
   on the 1k-client number blocks the change (Tier discipline: measure, and
   revert if it regresses).
4. **Diff touches cairn-core/cairn-client:**
   `cargo run -p cairn-client --example reactive_scroll` — must complete with
   the resume-after-restart property intact (exit 0, "resumed" in output).
5. **Diff touches cairn-ffi-wasm:** `wasm-pack build crates/cairn-ffi-wasm --target web`
   and check the gzipped size stays under the 500 KB budget (ADR-0015; currently 17 KB).

Report what rungs ran with real output, not "should pass".
