// @cairn/react-native — Codegen Turbo Native Module spec.
//
// This file is the CONTRACT the Wave-B native modules (Android Kotlin + iOS
// Swift) implement. It mirrors the UniFFI `CairnClient` surface exported by
// `sdk/cairn_swift/src/lib.rs` and `sdk/cairn_kotlin/src/lib.rs` —
// connect / subscribe / write / query / checkpoint — so the SAME
// `cairn_client::SyncClient<SqliteStorage>` that powers the native, Tauri,
// Flutter, Swift, Kotlin, and Node SDKs is reachable from JS over JSI.
//
// WHY A NATIVE MODULE (not WASM)
// --------------------------------
// RN's Hermes engine does NOT ship `global.WebAssembly` (Hermes issue #429,
// OPEN as of RN 0.84; the RN 0.84 release notes have zero WASM mentions).
// Cairn's `@cairn/web` WASM core (`cairn-ffi-wasm`) is therefore a dead end
// inside RN. This TurboModule bridges to the already-shipped `cairn-swift` /
// `cairn-kotlin` UniFFI bindings instead — the SAME shape PowerSync's RN SDK
// validated (pure-TS facade over a native JSI backend).
//
// METHOD-BY-METHOD MAPPING (spec → UniFFI in sdk/cairn_swift + sdk/cairn_kotlin)
//   connect(url, token, dbPath) → CairnClient::new(url, token, db_path) + CairnClient::connect() -> Result<(), CairnError>
//   subscribe(table)          → CairnClient::subscribe(table: String) -> Result<(), CairnError>
//   write(table, op, pk, pj)  → CairnClient::write(table, op, pk, payload_json: Option<String>) -> Result<u64, CairnError>
//   query(sql)                → CairnClient::query(sql: String) -> Result<String, CairnError>  (JSON rows)
//   checkpoint()              → CairnClient::checkpoint() -> Result<u64, CairnError>
//   watchChanges(table, cb)   → CairnClient::watch(table, sink: SnapshotSink)  (kotlin, UniFFI
//                              `with_foreign` sync callback) / cairn_node::CairnClient::watch(table, on_snapshot)
//                              (napi ThreadsafeFunction). Rust→JS PUSH: the native side retains `cb` and invokes
//                              it on the JS thread with a full-snapshot JSON string for the INITIAL snapshot,
//                              then again after every applied change (drains subscribe_changes() + re-queries
//                              storage per tick). The RN analogue of both sibling seams is a Codegen-emitted
//                              retained JS callback (JSI), invoked from the change pump via a JS-thread hop.
//   unwatchChanges(table)     → tears the per-table push pump + releases the retained callback. This is the
//                              `stop_watch(table)` follow-on the kotlin/node ports DEFERRED (their ceiling);
//                              RN ships it from day 1 so the JS facade can unsubscribe cleanly.
//   setToken(token)           → CairnClient::set_token(token: Option<String>) (ADR-0029 #3). Hot-swap the
//                              bearer on the interior-mutable token cell — the reconnect loop reads it on
//                              its NEXT attempt, so a live session picks up the new token with NO disconnect.
//                              `null` = clear (anonymous). Callable before connect AND on a live session.
//   signOut()                 → CairnClient::sign_out() (ADR-0029): abort run loop → await quiesce →
//                              clear_local_state (rows + checkpoint + epoch + outbox + dead-letter) → drop
//                              session → clear token. Idempotent; the "B must not see A's rows" wipe.
//
// Wave-B note: TurboModules are singletons instantiated by RN with a no-arg
// constructor — there is no JS-visible constructor surface to pass (url, token,
// dbPath) through. The spec therefore grows `connect(url, token, dbPath)` so
// the Kotlin module can lazily construct `uniffi.cairn_kotlin.CairnClient` on
// first `connect(...)`. The TS facade (`CairnClient.ts`) captures these in its
// config and passes them through on `connect()`.
//
// The native side blocks on its OWN tokio runtime (UniFFI sync methods — see
// the `ponytail:` in sdk/cairn_swift/src/lib.rs for why block-on-owned-runtime
// beat UniFFI async) and surfaces results to JS as resolved Promises. The
// JS-side API is therefore fully Promise-returning.

import type { TurboModule } from "react-native";
import { TurboModuleRegistry } from "react-native";

// Consumed by `@react-native/codegen` at native-build time (Wave B) to emit the
// C++/ObjC/Java bindings. `type: "modules"` = TurboModule (vs "components").
export const codegenConfig = {
  name: "NativeCairn",
  type: "modules",
  jsSrcsDir: "src",
};

/**
 * The TurboModule spec. Wave B's Kotlin/Swift implementations MUST satisfy
 * this interface exactly — Codegen generates the native bindings from it, and
 * drift between this spec and the native module's actual methods surfaces at
 * runtime as `TurboModuleRegistry.getEnforcing(...)` returning null (the
 * native side failed to register a conforming module).
 *
 * `payloadJson` is `string | null`: `null` matches UniFFI's
 * `Option<String>::None` (deletes carry no row image); a JSON string matches
 * `Some(String)`. The codegen TS parser recognizes `| null` as a nullable
 * annotation.
 */
export interface Spec extends TurboModule {
  /**
   * Construct the backing UniFFI `CairnClient(url, token, dbPath)` (idempotent
   * — re-connect reuses the existing handle) and open the local SQLite store +
   * build the SyncClient. No network I/O until `subscribe(table)`.
   *
   * `url` is the sync spine's WebSocket URL (e.g. `ws://host:port/sync`);
   * `token` is the optional auth bearer (null for anonymous); `dbPath` is the
   * SQLite file path (`:memory:` for ephemeral). These three match the UniFFI
   * `CairnClient::new` constructor args 1:1.
   */
  connect(url: string, token: string | null, dbPath: string): Promise<void>;
  /**
   * Start the live replication loop for `table` on the native side (spawns
   * `client.run_with_reconnect()` on the owned tokio runtime). The app polls
   * `query(sql)` / the facade's `pollRows(table)` to drain applied rows —
   * there is no row-tick callback to JS in this wave.
   */
  subscribe(table: string): Promise<void>;
  /**
   * Write a row. `op` is one of `"upsert"` | `"delete"` | `"patch"` (matches
   * `WriteOp::as_wire_str` in cairn-core; the native side rejects anything
   * else). Returns the durable sequence number / LSN.
   */
  write(
    table: string,
    op: string,
    pk: string,
    payloadJson: string | null,
  ): Promise<number>;
  /**
   * Run SQL against the on-device SQLite store. Returns a JSON-ROWS string
   * (UniFFI can't return `Vec<HashMap>` directly). The facade decodes it.
   */
  query(sql: string): Promise<string>;
  /** Current durable LSN (the resume_lsn on reconnect). */
  checkpoint(): Promise<number>;
  /**
   * Subscribe to a stream of full-table snapshots for `table`. The native side
   * retains `onSnapshot` and invokes it ON THE JS THREAD (the RN analogue of
   * napi's `ThreadsafeFunction` in cairn_node and the `SnapshotSink` UniFFI
   * callback in cairn_kotlin): once with the INITIAL snapshot immediately, then
   * again after every applied change. Each invocation carries a JSON
   * array-of-objects string — a FULL snapshot per tick (not a diff; self-healing
   * on lag), the same shape `query()` returns.
   *
   * The returned Promise resolves AFTER the initial snapshot has been emitted
   * to `onSnapshot`, so the caller knows the first frame has fired.
   *
   * Wave-B Codegen note: a `(rowsJson: string) => void` param is emitted as a
   * retained JS callback the native impl invokes repeatedly from the change
   * pump. NEVER call it from a background thread — marshal onto the JS thread
   * (the module's owned-runtime → JS-thread hop), exactly as napi's
   * `ThreadsafeFunction` schedules onto the libuv loop.
   */
  watchChanges(
    table: string,
    onSnapshot: (rowsJson: string) => void,
  ): Promise<void>;
  /**
   * Tear down the per-table push pump started by `watchChanges(table)` and
   * release the retained JS callback. After this resolves, `onSnapshot` will
   * not be invoked again for `table`. Idempotent.
   */
  unwatchChanges(table: string): Promise<void>;
  /**
   * Hot-swap the auth bearer WITHOUT tearing down the live session
   * (ADR-0029 #3). Maps to UniFFI `CairnClient::set_token(token: Option<String>)`
   * in cairn-swift / cairn-kotlin: it swaps the interior-mutable token cell the
   * reconnect loop reads on its NEXT attempt, so an already-running session
   * picks up the new token without a forced disconnect. Pass `null` to clear
   * (anonymous).
   *
   * Callable before `connect()` (stages the token for the first connect) AND on
   * a live session. It does NOT force a reconnect or tear anything down — the
   * same shape `cairn-client`'s `SyncClient::set_token` exposes.
   */
  setToken(token: string | null): Promise<void>;
  /**
   * Sign out (ADR-0029): abort the run loop, await quiescence, wipe local state
   * (rows + checkpoint + epoch + outbox + dead-letter), drop the session, and
   * clear the token. Maps to UniFFI `CairnClient::sign_out()`. The next
   * principal connecting on the same device sees a clean store — the "B must
   * not see A's rows, and A's unsynced writes must not be attributed to B"
   * guarantee. Idempotent — a no-op if no session is live.
   */
  signOut(): Promise<void>;
}

export default TurboModuleRegistry.getEnforcing<Spec>("NativeCairn");
