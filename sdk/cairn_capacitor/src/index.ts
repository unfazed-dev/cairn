// Copyright (c) Cairn contributors
// SPDX-License-Identifier: Apache-2.0
//
// @cairn/capacitor — a Capacitor v8 web-only plugin that re-exports
// @cairn/web's live browser sync path. The mobile webview (iOS WKWebView,
// Android WebView) is a full browser engine, so the wasm CairnSocket
// (web-sys::WebSocket + Window::localStorage) runs unmodified — there is NO
// native android/ or ios/ source in this package. The `web` implementation
// registered below does all the work.
//
// Usage in a Capacitor app:
//
//   import { Cairn } from "@cairn/capacitor";
//   await Cairn.configure({ wasmUrl: "assets/cairn_ffi_wasm.js" });
//   await Cairn.connect({ url: "wss://sync.example.com/sync", table: "tasks" });
//   await Cairn.write({ table: "tasks", op: "upsert", pk: "t1",
//                       payload: { title: "hi" }, clientWriteId: "w1" });
//   const { rows } = await Cairn.query({ table: "tasks" });

import { registerPlugin } from "@capacitor/core";

import type { CairnPlugin } from "./definitions";

export type {
  CairnConnectResult,
  CairnForegroundPushEvent,
  CairnPlugin,
  CairnPushTokenEvent,
  CairnRow,
  CairnWatchSnapshot,
  CairnWatchSubscription,
  ConfigureOptions,
  ConnectOptions,
  QueryOptions,
  SetTokenOptions,
  WatchOptions,
  WriteOptions,
  PushPlatform,
} from "./definitions";
export { CairnWeb } from "./web";

/**
 * The Cairn plugin handle. Calling any method on this proxy dispatches to the
 * registered web implementation (the only implementation in this package).
 * The lazy `web` loader lets bundlers code-split the wasm glue.
 */
export const Cairn = registerPlugin<CairnPlugin>("Cairn", {
  web: () => import("./web").then((m) => new m.CairnWeb()),
});
