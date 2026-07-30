# Capacitor — `@cairn/capacitor`

Extracted from `sdk/cairn_capacitor/src/definitions.ts` on 2026-07-30.
Index: [`README.md`](README.md).

A Capacitor plugin wrapping [`@cairn/web`](web.md)'s WASM engine, so it works on the web target as
well as native shells. Reads are the **KV store**, not SQL.

## `CairnPlugin`

`definitions.ts:94`. Every method takes a single options object — Capacitor's convention.

| Method | Signature |
|---|---|
| `configure` | `configure(options: ConfigureOptions): Promise<void>` |
| `connect` | `connect(options: ConnectOptions): Promise<CairnConnectResult>` |
| `subscribe` | `subscribe(options: { table: string; whereSql?: string \| null }): Promise<void>` |
| `write` | `write(options: WriteOptions): Promise<void>` |
| `query` | `query(options: QueryOptions): Promise<{ rows: CairnRow[] }>` |
| `checkpoint` | `checkpoint(): Promise<{ checkpoint: number }>` |
| `rowCount` | `rowCount(): Promise<{ rowCount: number }>` |
| `close` | `close(): Promise<void>` |

Returns are **wrapped objects**, not bare values — `{ checkpoint }` and `{ rowCount }`, not a
number. Easy to trip on.

### Option shapes

| Interface | Fields |
|---|---|
| `ConfigureOptions` | `wasmUrl: string` — where the plugin loads the WASM bundle from |
| `ConnectOptions` | `url: string`, `token?: string \| null`, `table?: string`, `whereSql?: string \| null` |
| `CairnConnectResult` | `rowCount: number`, `checkpoint: number` |
| `WriteOptions` | `table: string`, `op: string`, `pk: string`, `payload?: unknown`, `payloadJson?: string`, `clientWriteId: string` |
| `QueryOptions` | `table: string` — a **table name, not SQL** |
| `CairnRow` | `pk: string`, `payload: unknown` |

Two things to notice in `WriteOptions`: `clientWriteId` is **required** (it is how a write is
de-duplicated if you retry), and `payload` / `payloadJson` are alternatives — pass the object or
the pre-serialised string, not both.

```ts
import { Cairn } from "@cairn/capacitor";

await Cairn.configure({ wasmUrl: "/assets/cairn_ffi_wasm_bg.wasm" });
const { rowCount } = await Cairn.connect({ url: "ws://127.0.0.1:8800/sync", table: "tasks" });
await Cairn.subscribe({ table: "tasks" });
await Cairn.write({
  table: "tasks", op: "upsert", pk: "1",
  payload: { title: "buy milk" }, clientWriteId: crypto.randomUUID(),
});
const { rows } = await Cairn.query({ table: "tasks" });
```

`configure` before `connect` — the plugin needs to know where its WASM lives, and the URL depends
on how your bundler emits assets.

## Ceilings

- **Reads are KV, not SQL** — `query` takes a table name and returns `{pk, payload}`. Inherited
  from the WASM apply engine (see [`web.md`](web.md)).
- One table per connection.
- No reactive stream — poll `query` after writes.
- **`package.json` depends on `"@cairn/web": "file:../cairn_web"`.** That path dependency breaks the
  moment this is published, so `@cairn/web` has to go to the registry first. A real publish
  blocker, not a nit.

## Proven by

`sdk-e2e` `capacitor` slice — builds the plugin, installs `example-app`, and runs Playwright
against it for a full PUSH + ECHO round-trip.
