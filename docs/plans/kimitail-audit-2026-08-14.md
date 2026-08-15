# Kimitail audit — whole codebase, 2026-08-14

Scope: crates/ (59k LOC), sdk/ (28.5k), web/src, apps/atlet, scripts/, archive/, docker/, packaging/.
Over-engineering and complexity only — correctness/security/perf out of scope. Nothing applied; this is a cut list, ranked biggest first. Five parallel audit agents; unused/claims grep-verified workspace-wide.

## Findings

1. ~~`delete:` 318-line attachment state machine in cairn-core with zero code consumers~~ **RETRACTED 2026-08-14 after investigation:** attachments.rs is ADR-0034's deliberate executable spec — the canonical state machine + wire strings the Dart/TS drivers shallowly duplicate, pinned by its own regression tests (`cols_are_stable_wire_identifiers`). Not dead code; do not delete. Verified no drift across the three copies (wire strings, backoff, dead-letter semantics all match). Remaining gap: nothing in CI mechanically cross-checks the Dart/TS copies against the Rust contract — a ~30-line test reading the SDK files would close it.
2. `shrink:` watch-pump/emitter/replay-cache copy-pasted ~3× across FFI SDKs — hoist one `SyncClient::watch_table` into cairn-client; each SDK keeps a ~5-line emit leaf. [sdk/cairn_node/src/lib.rs:117-377, sdk/cairn_dotnet/src/lib.rs:129-561, sdk/cairn_tauri/src/lib.rs:133-578] (~180 lines)
3. `shrink:` predicate tokenizer duplicated — scope.rs mirrors predicate_compile.rs's tokenizer verbatim (its own doc says so); one shared tokenizer parameterized over dotted idents. [crates/cairn-domain/src/scope.rs:251-388 vs predicate_compile.rs:94-224] (~120 lines)
4. `shrink:` pool-of-one `client()`/`return_client()`/`drop_client()` pasted 4× in Pg adapters — one crate-private `LazyClient` struct. [crates/cairn-infra/src/write_back.rs:291, schema_source.rs:77,178, snapshot_source.rs:108] (~85 lines)
5. `shrink:` OR-set/counter read-merge-write branch pair duplicated in 3 sqlite.rs methods — one `merged_payload()` helper. [crates/cairn-client/src/sqlite.rs:676,770,1204] (~70 lines)
6. `shrink:` tenant-guarded CTE + EXISTS probe duplicated 3× (delete/patch/increment) — one `guarded_write()` helper. [crates/cairn-infra/src/write_back.rs:742,907,1049] (~60 lines)
7. `stdlib:` hand-rolled HS256 JWT verify + base64url decode + exp check in auth.rs — `jsonwebtoken` is already this crate's dep (jwks.rs) and does all three. [crates/cairn-infra/src/auth.rs:159] (~60 lines)
8. `shrink:` `or_set_merge`/`counter_merge` byte-identical except one call — one `merge_into_jsonb(…, merge_fn)`. [crates/cairn-infra/src/write_back.rs:325,389] (~55 lines)
9. `shrink:` epoch/rules-checksum meta read+write quadruplication — `meta_get(key)`/`meta_set(key,val)` collapse all four. [crates/cairn-client/src/sqlite.rs:537] (~50 lines)
10. `delete:` `Predicate::ne/lt/gt/le/ge/or_eq` delegation builders with no production callers (production builds `PredicateExpr::*` directly). Keep `eq`/`all`. [crates/cairn-domain/src/predicate.rs:299-375] (~60 lines)
11. `delete:` `SqliteStorage::dead_letter_entries` — pub fn with zero callers outside its own test (UI reads `WriteQueueStatus.dead_lettered`). [crates/cairn-client/src/sqlite.rs:327] (~45 lines)
12. `stdlib:` hand-rolled `Ordering` enum + `to_ordering` duplicates `std::cmp::Ordering` incl. its exact is_lt/is_gt methods. [crates/cairn-domain/src/predicate.rs:464-488,546-555] (~35 lines)
13. `yagni:` 6 verbatim "table not in active subscription" guards in the Dart SDK — one `_requireSubscribed(table, verb)`. [sdk/cairn_flutter/lib/src/cairn.dart:319-431] (~35 lines)
14. `shrink:` docker-compose.stack.yml re-declares the whole postgres service verbatim — make it an overlay (`-f docker-compose.yml -f stack.yml`, pattern Makefile:150 already uses). [docker/docker-compose.stack.yml] (~30 lines)
15. `shrink:` `dispatch_write`'s upsert/patch/increment arms repeat the payload-object guard — one `require_object(payload, op)?`. [crates/cairn-infra/src/transport.rs:1097] (~30 lines)
16. `delete:` Tauri `abort_subscribe` unreachable from JS (absent from `generate_handler!` and permissions; only in-file tests call it). [sdk/cairn_tauri/src/lib.rs:292-302] (~25 lines)
17. `delete:` dead web SDK exports — `CairnEngine`/`Frame` re-exports, `AttachmentConstants`, `QUEUED`, `DEFAULT_MAX_ATTEMPTS`/`onSuccess`, `SyncStatus` in index.d.ts. [sdk/cairn_web/index.js:325-335, attachments.js:43,359-361, index.d.ts:47-50] (~25 lines)
18. `yagni:` `Subscribe.filters` wire field no shipped client populates (rust sends `vec![]`; `where_sql` supersedes) — drop `FilterClause` + fold loop; serde `default` keeps old frames parsing. [crates/cairn-infra/src/wire.rs:107] (~25 lines)
19. `shrink:` 3 status listeners + signOut hand-copy all 7 SyncStatus fields — `copyWith` + shared `_cancelListeners()`. [sdk/cairn_flutter/lib/src/cairn_database.dart:536-675] (~25 lines)
20. `shrink:` `encode_event` duplicates `event_to_frame_value` arm-for-arm — `serde_json::to_vec(&event_to_frame_value(event))`. [crates/cairn-infra/src/wire.rs:130] (~20 lines)
21. `shrink:` `memchr_looks_like_write_result` + hand-rolled contains — `std::str::from_utf8(bytes).is_ok_and(|s| s.contains("write_result"))`. [crates/cairn-client/src/client.rs:1477] (~20 lines)
22. `delete:` `with_push_interval` knob + `run()` sleep branch, zero callers repo-wide. [crates/cairn-application/src/fanout.rs:73-76,136-144,319-324] (~22 lines)
23. `delete:` `InMemoryStorage` builder methods only their own tests use (real consumer uses `set_*`); plus `_storage_error_is_reachable` stub and test-only `outbox_len`. [crates/cairn-core/src/in_memory.rs:52-68,118-122,341-348] (~30 lines)
24. `yagni:` Tauri `CairnState.rt: Option<Runtime>` + Drop thread-offload exists only for `#[tokio::test]`. [sdk/cairn_tauri/src/lib.rs:93,587-605] (~15 lines)
25. `shrink:` flutter slice in sdk-e2e.sh re-implements `run_slice` bookkeeping — optional skip-pattern arg. [scripts/sdk-e2e.sh:104-126] (~13 lines)
26. `delete:` `Lsn::advance` — no callers outside its own test. [crates/cairn-domain/src/lsn.rs:40-52] (~13 lines)
27. `shrink:` `outbox_has_column`/`cairn_data_has_column` identical except table name — one `has_column(conn, table, needle)`. [crates/cairn-client/src/sqlite.rs:1366] (~12 lines)
28. `delete:` dangling Dart doc comments describing classes that don't exist in the file. [sdk/cairn_flutter/lib/src/schema.dart:164-171] (~8 lines)
29. `delete:` dead `themeObs` MutationObserver with empty callback, unread `stage` var, never-sent `'pulse'` bus variant. [web/src/lib/components/CairnField.svelte:332-347,39,363,48-52] (~8 lines)
30. `shrink:` `_Pending` pure-delegation wrapper over `Completer` — use `Completer` directly. [sdk/cairn_flutter/lib/src/engine_web.dart:376-431] (~7 lines)
31. `delete:` duplicate `QUEUED` set in worker_attachment_gateway.js — derive from ./attachments.js. [sdk/cairn_web/worker_attachment_gateway.js:29-33,110] (~7 lines)
32. `delete:` worker `ping` command — slice-1 probe only legacy spec uses. [sdk/cairn_web/worker/cairn.worker.js:184-188] (~6 lines)
33. `delete:` `mdsvex` configured for `.md` routes but zero `.md` files exist. [web/svelte.config.js:2,13-14,19,22] (~5 lines + dep)
34. `delete:` `outbox_has_column` covered above; `TASKS_TABLE` pub const zero refs. [crates/cairn-domain/src/lib.rs:44-45] (~2 lines)
35. `shrink:` `_decode`'s string/array branches — structured-clone preserves `Uint8Array`; keep one path. [sdk/cairn_web/worker_attachment_gateway.js:50-57] (~8 lines)
36. `yagni:` `crown` prop on the Cairn glyph — every site renders the default. [web/src/lib/components/ui/Cairn.svelte:9,21-23] (~3 lines)
37. `delete:` `ui = []` feature in cairn-cloud — zero `cfg(feature = "ui")` gates. [crates/cairn-cloud/Cargo.toml] (~2 lines + flag)
38. `shrink:` `_decode` dup covered; `bytes`/`tower`/`tower-http` unused in cairn-cloud deps, `serde` unused in cairn-client, `cairn-domain` unused in cairn_node, `@cairn/web` unused in cairn_capacitor, `serde`+`serde_json` unused in cairn-core, `uuid` unused in cairn-application, `three`+`@types/three`+`cupertino_icons` unused in web/atlet. [respective Cargo.toml/package.json files] (−11 deps; also 3 redundant dev-dep re-declarations)

## Checked and deliberately not flagged

Hexagonal port traits (all have real impls + callers); `fnv.rs` (cheaper than a dep); CRDT module (fully wired per ADRs); snapshot-reconcile/outbox contracts (load-bearing); `CairnEngine`/`CairnWorkerPort` Dart traits (2 real impls each, forced by frb); legacy Dart aliases (doc/example readers); archive/ (operator-ruled reference); render-playbook.py unused blocks (byte-identical-with-upstream policy); all `ponytail:`/`kimitail:` marked debt; web demo/landing/admin pages; cairn_adapter vs powersync_adapter (two impls is the product).

net: -1,209 lines, -13 deps possible (finding 1 retracted after investigation — see above).
