# React Native — `@cairn/react-native`

Extracted from `sdk/cairn_react_native/src/` on 2026-07-30. Index: [`README.md`](README.md).

A TurboModule over **`cairn_kotlin`'s `.so` and UniFFI bindings** — the same Rust client, reached
from JS. Real SQLite, real socket (ADR-0020).

## `CairnClient`

`src/CairnClient.ts:54`. The friendly facade; `src/NativeCairn.ts` is the raw TurboModule spec.

```ts
import { CairnClient } from "@cairn/react-native";

const client = new CairnClient({
  url: "ws://10.0.2.2:8800/sync",   // 10.0.2.2 = host, from an Android emulator
  token: null,
  dbPath: ":memory:",               // defaults to ":memory:" if omitted
});

await client.connect();
const sub = await client.subscribe("tasks");
await client.write("tasks", "upsert", "1", { title: "buy milk" });
const rows = await client.pollRows("tasks");
sub.unsubscribe();
```

| Member | Signature | Notes |
|---|---|---|
| constructor | `new CairnClient(config: CairnClientConfig)` | `{ url?, token?, dbPath? }`; `dbPath` defaults to `":memory:"` |
| `connect` | `connect(): Promise<void>` | opens SQLite + builds the client. **No network.** Throws with a message naming the fix if no `url` was configured |
| `subscribe` | `subscribe(table: string): Promise<Subscription>` | **opens the socket.** Idempotent — re-subscribing the same table reuses the handle, and the native side guards too |
| `write` | `write(table: string, op: WriteOp, pk: string, payload?: unknown): Promise<number>` | `WriteOp = "upsert" \| "delete" \| "patch"` — a real union type, so a typo is a compile error |
| `query` | `query(sql: string): Promise<Row[]>` | the facade decodes the native JSON string for you |
| `pollRows` | `pollRows(table: string): Promise<Row[]>` | convenience for `SELECT * FROM <table>` |
| `checkpoint` | `checkpoint(): Promise<number>` | durable LSN |

`Row` is `Record<string, unknown>`. `Subscription` carries `table` and `unsubscribe()`.

## Native spec

`src/NativeCairn.ts` is what Codegen generates bindings from, and it must match the Kotlin module
exactly — drift shows up at runtime as `TurboModuleRegistry.getEnforcing(...)` returning null.
Note `payloadJson: string | null` there: `null` maps to UniFFI's `Option<String>::None` (deletes
carry no row image), and the codegen TS parser recognises `| null` as nullable.

`query` returns a **JSON string** at the native boundary — UniFFI cannot return `Vec<HashMap>`.
`CairnClient` is the layer that parses it.

## Ceilings

- **Android only.** The iOS TurboModule is a fast-follow; `cairn_swift` is already
  simulator-proven, so the pieces exist.
- **One table per client** in v1.
- **No row-tick callback to JS** in this wave — nothing pushes at you. Poll `pollRows`/`query`
  after writes or on a timer.
- From an emulator the host is `10.0.2.2`, not `127.0.0.1`.

## Scripts

`npm test` runs `typecheck` **and** jest. It did not always: `typecheck` was a declared script
nothing executed, which is how a strict-mode type error survived in `connect()` — `url` is optional
in the config but the native spec requires a string.

## Proven by

`sdk-e2e` `reactnative` slice — `scripts/run-android-e2e.sh` builds the `.so`, spawns the spine, and
runs an instrumented PUSH + ECHO round-trip on a booted emulator.
