/**
 * @cairn/tauri — typed guest bindings for the cairn Tauri 2 plugin.
 *
 * Thin wrappers over invoke("plugin:cairn|<command>") mirroring the Rust
 * surface in sdk/cairn_tauri/src/lib.rs. Two tiers, one import:
 *
 *   import { cairn, upsert, query, watch } from "@cairn/tauri";
 *   await cairn.connect({ url, token, dbPath });
 *   const id = await upsert("tasks", "t1", { title: "Walk dog" });
 *
 * - Raw tier: connect/subscribe/write/query/checkpoint — the exact command
 *   surface (write takes op + a pre-stringified payload; query returns a JSON
 *   string). Kept verbatim so a JS caller can always drop to the metal.
 * - Sugar tier: upsert/patch/delete/writeBatch — the unified-verb naming the
 *   cairn-dx-audit standardizes on (payloads pass objects, not strings).
 *
 * Command args are camelCase on the wire (Tauri's default
 * ArgumentCase::Camel); these wrappers spell them the same way.
 *
 * @license Apache-2.0
 */

import { invoke, Channel } from "@tauri-apps/api/core";

/** The invoke prefix every cairn command is namespaced under. */
const CMD = "plugin:cairn|";

/**
 * Raw tier — the exact Rust command surface.
 *
 * connect() does NO network I/O: it opens SQLite + builds the client. A
 * subscribe() (or watch()) must follow or no server-pushed row ever arrives.
 * Every field is optional when the plugins.cairn config block in
 * tauri.conf.json supplies defaults (syncUrl / token / table / dbPath).
 */
export const cairn = {
  /** Open the local store + build the SyncClient. No network I/O. */
  connect(options = {}) {
    const { url, token, dbPath } = options ?? {};
    return invoke(`${CMD}connect`, { url, token, dbPath });
  },

  /** Start the live-replication run loop (server -> on-device rows). */
  subscribe(table) {
    return invoke(`${CMD}subscribe`, { table });
  },

  /**
   * Enqueue a durable write. Resolves with the outbox id once the write is
   * durable LOCALLY (ADR-0013), not when the server acks it. op is
   * "upsert" | "delete" | "patch"; payloadJson is a JSON string or null.
   */
  write(table, op, pk, payloadJson) {
    return invoke(`${CMD}write`, { table, op, pk, payloadJson });
  },

  /** Run a SELECT; resolves with a JSON array-of-objects string. */
  query(sql) {
    return invoke(`${CMD}query`, { sql });
  },

  /** Read the durable LSN checkpoint (u64; fresh store = 0). */
  checkpoint() {
    return invoke(`${CMD}checkpoint`);
  },

  /**
   * Reactive watch (ADR-0024): push the full table snapshot to onSnapshot
   * immediately, and again after every change tick (remote apply OR local
   * write) — a Rust->JS push, NOT a poll. Drop the returned disposer (or
   * call it) to end the pump; signOut tears everything down too.
   */
  watch(table, onSnapshot) {
    const channel = new Channel();
    channel.onmessage = onSnapshot;
    const done = invoke(`${CMD}watch`, { table, onEvent: channel }).then(() => () => {});
    // The pump self-terminates when JS drops the Channel; this disposer is
    // belt-and-braces for explicit teardown.
    return () => {
      channel.handler = undefined; // drop the JS-side handler
    };
  },

  /** Swap the auth token on the LIVE client (ADR-0029 refresh self-heal). */
  setToken(token) {
    return invoke(`${CMD}set_token`, { token });
  },

  /**
   * ADR-0029 sign-out: stop sync, wipe local rows + outbox + checkpoint,
   * clear the token, deregister session push tokens, drop the session.
   * Idempotent.
   */
  signOut() {
    return invoke(`${CMD}sign_out`);
  },

  /**
   * ADR-0037 §3: register this device's push token (POST /push-tokens) with
   * the same auth the sync connection uses. platform is "fcm" | "apns" |
   * "webpush"; on iOS/Android the token comes from the shell's native push
   * hooks. Desktop apps usually skip this (no OS rail — WS delivers).
   * Registered tokens are deregistered by signOut automatically.
   */
  registerPushToken(platform, token) {
    return invoke(`${CMD}register_push_token`, { platform, token });
  },

  /**
   * ADR-0037 §3: deregister one push token (DELETE /push-tokens/{token});
   * call when the app can no longer receive on it.
   */
  deregisterPushToken(token) {
    return invoke(`${CMD}deregister_push_token`, { token });
  },
};

// ---------------------------------------------------------------------------
// Sugar tier — the unified-verb naming standardized in the cairn-dx-audit
// (docs/plans/cairn-integration-tauri-flutter-push.md, DX section). Same
// commands under the hood; objects instead of pre-stringified payloads.
// ---------------------------------------------------------------------------

/**
 * Upsert one row (object payload). The write applies locally at once and
 * flushes to the server on the next connect — the offline-first contract.
 * Resolves with the outbox id.
 */
export function upsert(table, pk, payload) {
  return cairn.write(table, "upsert", pk, JSON.stringify(payload ?? {}));
}

/** Column-level update: send only the changed columns. */
export function patch(table, pk, changedColumns) {
  return cairn.write(table, "patch", pk, JSON.stringify(changedColumns ?? {}));
}

/** Delete one row by primary key. */
export function deleteRow(table, pk) {
  return cairn.write(table, "delete", pk, null);
}

/**
 * Fire N writes through the raw tier without awaiting each — they enqueue
 * independently into the same outbox, so one await-per-write is unnecessary.
 * Resolves with the outbox ids in order. (The Rust writeBatch verb lands
 * with the unified-verb wave; this composes the same contract from JS.)
 */
export async function writeBatch(writes) {
  const ids = [];
  for (const w of writes) {
    ids.push(
      await cairn.write(
        w.table,
        w.op ?? "upsert",
        w.pk,
        w.payload == null ? null : JSON.stringify(w.payload),
      ),
    );
  }
  return ids;
}

/**
 * watch + parse in one step: subscribe to the reactive snapshot stream and
 * hand each parsed row array to onRows. Returns a disposer.
 */
export function watchRows(table, onRows) {
  return cairn.watch(table, (snapshot) => onRows(snapshot.rows));
}

/**
 * query + JSON.parse in one step. Prefer this over raw query() unless the
 * raw string is wanted.
 */
export async function fetchAll(sql) {
  return JSON.parse(await cairn.query(sql));
}

export default cairn;
