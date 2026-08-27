# @cairn/tauri

Typed JS/TS guest bindings for the [`cairn_tauri`](../README.md) Tauri 2
plugin. Thin wrappers over `invoke("plugin:cairn|…")` with two tiers in one
import:

- **Raw tier** (`cairn.*`) — the exact Rust command surface:
  `connect / subscribe / write / query / checkpoint / watch / setToken /
  signOut / registerPushToken / deregisterPushToken`.
- **Sugar tier** — the unified-verb naming from the cairn DX audit:
  `upsert / patch / deleteRow / writeBatch / watchRows / fetchAll` (object
  payloads, parsed rows).

## Install

The package is not published to npm — consume it as a path dependency from
the cairn repo (arxa pins a tagged cairn checkout):

```jsonc
// package.json
"dependencies": {
  "@cairn/tauri": "file:../cairn/sdk/cairn_tauri/guest-js"
}
```

Requires `@tauri-apps/api` ^2 (peer dependency) and the Rust plugin
registered:

```rust
tauri::Builder::default().plugin(cairn_tauri::init())
```

plus the capability grant (see `example.capability.json`):

```json
{ "permissions": ["cairn:default"] }
```

## Config (tauri.conf.json)

```jsonc
{
  "plugins": {
    "cairn": {
      "syncUrl": "ws://127.0.0.1:8080/sync",
      "token": null,
      "table": "tasks",
      "dbPath": "cairn.db"
    }
  }
}
```

All fields optional — with the block populated, `connect()` takes no args.
Per-call args override config; config overrides the floor (`"tasks"` /
`"cairn.db"`). A typo'd key fails plugin init loudly.

## Usage

```js
import { cairn, upsert, watchRows, fetchAll } from "@cairn/tauri";

// connect() does NO network I/O — subscribe()/watch() drives replication.
await cairn.connect();                       // config-supplied defaults
await cairn.subscribe("tasks");

const id = await upsert("tasks", "t1", { title: "Walk dog" });
const stop = watchRows("tasks", (rows) => render(rows));
const all = await fetchAll("SELECT pk, payload FROM cairn_data WHERE table_name = 'tasks'");

// Push registration (ADR-0037 §3) — mobile shells pass the native token:
await cairn.registerPushToken("fcm", fcmToken);
// signOut deregisters session tokens automatically.
```

## Semantics pinned in the Rust crate

- `write` resolves on LOCAL durability (ADR-0013), not server ack.
- `watch` pushes a full snapshot per change tick (ADR-0024) — not a poll.
- `signOut` wipes local state and deregisters push tokens (ADR-0029 +
  ADR-0037 §3).
- Push registration rides `POST /push-tokens` with the sync credential —
  the same pinned REST contract as the Flutter and Node SDKs.

## License

Apache-2.0.
