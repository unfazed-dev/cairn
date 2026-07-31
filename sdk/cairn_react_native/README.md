# @cairn/react-native

React Native facade over the **cairn-swift** (iOS) and **cairn-kotlin** (Android)
UniFFI bindings. PowerSync-shaped API (`connect` / `subscribe` / `write` /
`query` / `checkpoint`), Promise-returning, with TWO row-access paths — poll
(`subscribe` + `pollRows`) and **reactive push** (`watch`). Same Rust
`cairn_client::SyncClient<SqliteStorage>` engine the native, Tauri, Flutter,
Swift, Kotlin, and Node SDKs drive — no engine/wire changes.

## Why a native module (not WASM)

Cairn's [`@cairn/web`](../cairn_web) ships a WebAssembly core
(`cairn-ffi-wasm`). React Native's **Hermes** engine does NOT ship
`global.WebAssembly` — [Hermes issue #429](https://github.com/facebook/hermes/issues/429)
is OPEN, and the RN 0.84 release notes have zero WASM mentions. So
`@cairn/web` is a dead end inside RN.

This package takes the path PowerSync's RN SDK validated: a **pure-TypeScript
facade** over a **Codegen Turbo Native Module** that calls the already-shipped
`sdk/cairn_swift` (iOS) and `sdk/cairn_kotlin` (Android) UniFFI bindings. No
WASM, no new Rust.

## Architecture

```
┌─────────────────────────────────────────────┐
│   React Native app  (JS / TypeScript)       │
│      new CairnClient(config)                │
│      await connect / subscribe / poll       │
└────────────────────┬────────────────────────┘
                     │ import NativeCairn from '@cairn/react-native'
                     │ (Codegen TurboModule spec — src/NativeCairn.ts)
                     ▼
┌─────────────────────────────────────────────┐
│  NativeCairn TurboModule  (JSI)             │      Wave B
│   • iOS:     ObjCNativeCairn.mm             │ ─────────────►  cairn-swift  (UniFFI)
│   • Android: KotlinNativeCairn.kt           │ ─────────────►  cairn-kotlin (UniFFI)
└─────────────────────────────────────────────┘
                                                       │
                                                       ▼
                                       ┌───────────────────────────────┐
                                       │ cairn_client::SyncClient<...> │
                                       │  (the same engine everywhere) │
                                       └───────────────────────────────┘
```

## Wave plan (tiering)

- **MUST — Wave A (this package, today):**
  TS facade + Codegen TurboModule spec + OFFLINE Jest smoke. Proves the facade
  wiring + the spec contract without a device. The Jest tests mock
  `NativeCairn` and exercise `connect → subscribe → query → write →
  checkpoint` (poll path) AND the reactive `watch()` push path — capturing the
  retained bridge callback the way the Wave-B change pump holds it, then
  asserting the facade decodes + fans out the initial snapshot and each
  change, synthesizes late-watcher initial snapshots, and tears the pump down
  on the last unsubscribe.

- **SHOULD — Wave B:**
  Android Kotlin TurboModule + instrumented emulator E2E (`connect() →
  query()` round-trip on emulator-5554, matching `sdk/cairn_kotlin`'s existing
  instrumented test). `@react-native/codegen` runs against `src/NativeCairn.ts`
  to emit the C++/Java bindings; the Kotlin module delegates each method to the
  UniFFI `CairnClient`.

- **NICE — Wave B/C:**
  iOS Swift TurboModule + simulator E2E. Lower priority than Android —
  `sdk/cairn_swift` is already verified, so the TurboModule wrapper is
  mechanical.

## Install

```sh
# In your RN app (Wave B+ — native module not yet shipped):
npm install @cairn/react-native
```

This Wave-A package has no native code — it is consumable as a TS library today
(the TurboModule resolves to a registered native module once Wave B lands).

## API

```ts
import { CairnClient } from "@cairn/react-native";

const client = new CairnClient({
  url: "ws://your.cairn.server/sync",
  token: "bearer-jwt",
  dbPath: "cairn.db", // ":memory:" for ephemeral
});

await client.connect();
await client.subscribe("tasks");

// Two ways to read applied rows:

// (1) REACTIVE — watch() PUSHES a fresh FULL snapshot whenever the underlying
//     rows change (initial snapshot + every delta), built on cairn-client's
//     hot-replay change stream — NOT a poll. The RN port of node's watch()
//     (napi ThreadsafeFunction) and kotlin's watch() (UniFFI SnapshotSink); the
//     push crosses JSI as a retained TurboModule callback.
const sub = await client.watch("tasks", (rows) => {
  console.log("current tasks:", rows); // initial snapshot, then each change
});
// …later:
sub.unsubscribe(); // stops this handle; pump tears down on the last handle

// (2) POLL — drain applied rows yourself (the Phase-1 floor).
const rows = await client.pollRows("tasks");

// Write: op is "upsert" | "delete" | "patch" (WriteOp wire strings).
await client.write("tasks", "upsert", "t1", { title: "Walk dog" });

// Durable checkpoint (resume_lsn on reconnect).
const lsn = await client.checkpoint();
```

## Methods (mirror UniFFI `CairnClient`)

The `NativeCairn` spec in `src/NativeCairn.ts` declares the surface the UniFFI
`CairnClient` in `sdk/cairn_swift` + `sdk/cairn_kotlin` exports — Wave B's
native modules must satisfy it byte-for-byte.

| facade                       | NativeCairn spec                              | UniFFI (swift / kotlin)                                            |
| ---------------------------- | --------------------------------------------- | ------------------------------------------------------------------ |
| `connect()`                  | `connect(): Promise<void>`                    | `CairnClient::connect() -> Result<()>`                             |
| `subscribe(table)`           | `subscribe(table): Promise<void>`             | `CairnClient::subscribe(table: String) -> Result<()>`              |
| `write(t, op, pk, payload?)` | `write(t, op, pk, pj: string\|null)`          | `CairnClient::write(t, op, pk, payload_json: Option<String>)`      |
| `query(sql)`                 | `query(sql): Promise<string>`                 | `CairnClient::query(sql: String) -> Result<String>` (JSON rows)    |
| `pollRows(table)`            | (uses `query`)                                | —                                                                  |
| `checkpoint()`               | `checkpoint(): Promise<number>`               | `CairnClient::checkpoint() -> Result<u64>`                         |
| `watch(table, onSnapshot)`   | `watchChanges(t, cb): Promise<void>`          | `CairnClient::watch(t, sink: SnapshotSink)` (kotlin) / node `watch` |
|                              | `unwatchChanges(table): Promise<void>`        | `stop_watch(table)` (the follow-on kotlin/node deferred)           |

`watch()` is the reactive push path (ADR-0024): the native side retains the JS
callback and invokes it on the JS thread with the initial snapshot, then after
every applied change — a full snapshot per tick, the same shape `query()`
returns. The facade multiplexes one native pump per table and reference-counts
teardown (`unwatchChanges` fires when the table's last handle unsubscribes).

## `unsafe` policy

Cairn's Rust is `#![forbid(unsafe_code)]` workspace-wide. The UniFFI
proc-macro FFI glue is the one machine-generated exception (ADR-0015 addendum).
This package's hand-written source is pure TypeScript — no `unsafe` concept
applies. Wave B's native module uses RN Codegen's generated JSI bindings; any
`unsafe` in that path lives in **RN's generated code**, not in Cairn-authored
source — same standing as the UniFFI / flutter_rust_bridge / napi-derive
exceptions.

## Wave-B unknowns (flagged)

1. **Config plumbing.** The UniFFI `CairnClient::new(url, token, db_path)` is a
   constructor, but RN TurboModules are singletons — there is no per-instance
   JS constructor in the spec. Wave B must decide: does the native module read
   `url`/`token`/`dbPath` from native app config (Android `gradle.properties` /
   iOS `Info.plist`), or does the spec grow a `setConfig()` method? The JS
   facade captures config in its constructor today so the public API is stable
   regardless.
2. **Codegen nullable-string param.** The spec uses `payloadJson: string | null`
   for the UniFFI `Option<String>` mapping. The codegen TS parser accepts
   `| null` as nullable, but Wave B is the first time codegen actually runs
   against this spec — verify before assuming.

## Develop

```sh
cd sdk/cairn_react_native
npm install --no-audit --no-fund
npm run build    # tsc -p tsconfig.build.json  →  dist/  (typecheck + emit)
npm test         # jest offline smoke
```

## License

Apache-2.0, end to end. See [`../../LICENSE`](../../LICENSE).
