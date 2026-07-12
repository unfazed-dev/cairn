// Copyright (c) Cairn contributors
// SPDX-License-Identifier: Apache-2.0
//
// Web implementation of the @cairn/capacitor plugin.
//
// This is the substantive file. It does NOT re-export @cairn/web's `index.js`
// (which is the node apply-engine-only facade — see the file header there for
// why: it loads the `--target nodejs` wasm build and deliberately does NOT
// open a WebSocket, because web-sys::WebSocket + Window::localStorage do not
// exist in Node without a polyfill).
//
// Instead, this file mirrors the wiring in
// `sdk/cairn_web/e2e/browser_live.spec.cjs`: it dynamically loads the
// `--target web` wasm glue (`@cairn/web`'s `pkg-web/cairn_ffi_wasm.js`), runs
// its default export to instantiate the wasm, then drives the `CairnSocket`
// class — a live WebSocket sync session built on web-sys::WebSocket +
// Window::localStorage. In a Capacitor webview (iOS WKWebView or Android
// WebView) both of those browser globals exist and behave exactly as in a
// desktop browser, so the live browser path runs unmodified.
//
// The wasm URL is configurable via {@link CairnWeb.configure}. The default
// `/pkg-web/cairn_ffi_wasm.js` is correct when the host serves the asset at
// that document-absolute path (the example app and Playwright E2E do this;
// bundled Capacitor apps override it to the bundled asset URL).

import { WebPlugin } from "@capacitor/core";
import type {
  CairnConnectResult,
  CairnPlugin,
  CairnRow,
  ConfigureOptions,
  ConnectOptions,
  QueryOptions,
  WriteOptions,
} from "./definitions";

/** Default URL of the wasm-pack `--target web` glue, served by the host. */
const DEFAULT_WASM_URL = "/pkg-web/cairn_ffi_wasm.js";

/**
 * Shape of the dynamically-imported wasm-pack `--target web` module. Kept as a
 * structural type (no runtime import — the URL is resolved at first use) so
 * the host can serve the asset from any path.
 */
interface WasmWebModule {
  /** wasm-pack's init; returns a Promise that resolves once wasm is ready. */
  default(): Promise<unknown>;
  /** The live WS sync session class. See pkg-web/cairn_ffi_wasm.d.ts. */
  CairnSocket: CairnSocketCtor;
}

/** Constructor shape for the wasm CairnSocket class. */
interface CairnSocketCtor {
  connect(
    url: string,
    token: string | null | undefined,
    table: string,
    whereSql?: string | null,
  ): Promise<CairnSocketInstance>;
}

/** Instance shape for the wasm CairnSocket. */
interface CairnSocketInstance {
  readonly rowCount: number;
  readonly checkpoint: number;
  rowsFor(table: string): Array<{ pk: string; payload: unknown }>;
  write(
    table: string,
    op: string,
    pk: string,
    payloadJson: string | null | undefined,
    clientWriteId: string,
  ): void;
  close(): void;
}

/**
 * Cairn's web-only Capacitor implementation. Delegates to the live browser
 * path supplied by @cairn/web's pkg-web wasm build. The class is exported for
 * direct construction by hosts that want to skip `registerPlugin`'s lazy
 * loader; the normal path is `registerPlugin('Cairn', { web: ... })` in
 * `src/index.ts`.
 *
 * Storage today is the wasm engine's in-memory KV (the same bar @cairn/web
 * sets). Durable storage arrives with @capacitor-community/sqlite (ADR-0017
 * upgrade path — see README).
 */
export class CairnWeb extends WebPlugin implements CairnPlugin {
  /** The active socket, set by connect, cleared by close. */
  private sock: CairnSocketInstance | null = null;

  /** Resolves to the wasm CairnSocket ctor once init completes. */
  private wasmPromise: Promise<CairnSocketCtor> | null = null;

  /** Configured wasm URL (configure() overrides the default). */
  private wasmUrl: string = DEFAULT_WASM_URL;

  /** @inheritDoc */
  async configure(options: ConfigureOptions): Promise<void> {
    if (!options || !options.wasmUrl) {
      throw new Error("Cairn.configure: wasmUrl is required");
    }
    // If init already ran with a different URL, drop the cached promise so
    // the next connect() re-imports at the new URL.
    if (this.wasmUrl !== options.wasmUrl) {
      this.wasmPromise = null;
    }
    this.wasmUrl = options.wasmUrl;
  }

  /** @inheritDoc */
  async connect(options: ConnectOptions): Promise<CairnConnectResult> {
    if (!options || typeof options.url !== "string" || !options.url) {
      throw new Error("Cairn.connect: url is required");
    }
    const CairnSocket = await this.loadWasm();
    // The wasm CairnSocket.connect appends ?token= on the URL itself (browsers
    // can't set headers on a WS handshake). We pass the raw URL.
    this.sock = await CairnSocket.connect(
      options.url,
      options.token ?? null,
      options.table ?? "tasks",
      options.whereSql ?? null,
    );
    return {
      rowCount: this.sock.rowCount,
      checkpoint: this.sock.checkpoint,
    };
  }

  /** @inheritDoc */
  async subscribe(_options: {
    table: string;
    whereSql?: string | null;
  }): Promise<void> {
    // ponytail: subscribe is folded into connect for the v0.1 web path. The
    // wasm CairnSocket is a single-session affordance that subscribes during
    // connect. Real multi-table subscribe arrives with ADR-0017 durable
    // storage + a session manager; this no-op keeps the interface
    // source-compatible with the native plugin shape.
    if (!this.sock) {
      throw new Error("Cairn.subscribe: connect() not called");
    }
  }

  /** @inheritDoc */
  async write(options: WriteOptions): Promise<void> {
    if (!this.sock) {
      throw new Error("Cairn.write: connect() not called");
    }
    if (!options || !options.table || !options.op || !options.pk) {
      throw new Error("Cairn.write: table, op, pk are required");
    }
    const payloadJson =
      options.payloadJson ?? JSON.stringify(options.payload ?? null);
    this.sock.write(
      options.table,
      options.op,
      options.pk,
      payloadJson,
      options.clientWriteId,
    );
  }

  /** @inheritDoc */
  async query(options: QueryOptions): Promise<{ rows: CairnRow[] }> {
    if (!this.sock) {
      throw new Error("Cairn.query: connect() not called");
    }
    if (!options || !options.table) {
      throw new Error("Cairn.query: table is required");
    }
    const rows = this.sock.rowsFor(options.table) ?? [];
    return {
      rows: rows.map((r) => ({
        pk: r.pk,
        payload: r.payload,
      })),
    };
  }

  /** @inheritDoc */
  async checkpoint(): Promise<{ checkpoint: number }> {
    if (!this.sock) {
      throw new Error("Cairn.checkpoint: connect() not called");
    }
    return { checkpoint: this.sock.checkpoint };
  }

  /** @inheritDoc */
  async rowCount(): Promise<{ rowCount: number }> {
    if (!this.sock) {
      throw new Error("Cairn.rowCount: connect() not called");
    }
    return { rowCount: this.sock.rowCount };
  }

  /** @inheritDoc */
  async close(): Promise<void> {
    const s = this.sock;
    this.sock = null;
    if (s) {
      try {
        s.close();
      } catch {
        // Already closed — fine.
      }
    }
  }

  /**
   * Dynamically import the wasm-pack `--target web` glue and instantiate the
   * wasm. Cached on this.wasmPromise so repeat connect() calls share the same
   * module. Throws on init failure; the cached promise is dropped so a later
   * retry can re-attempt.
   */
  private loadWasm(): Promise<CairnSocketCtor> {
    if (this.wasmPromise) {
      return this.wasmPromise;
    }
    const url = this.wasmUrl;
    // Dynamic import of a URL resolved at runtime — browsers and Capacitor
    // webviews handle this natively (the parent document's import map or the
    // bundler's config resolve any bare specifier in the glue; the glue
    // itself is served as a URL). The cast through unknown is necessary
    // because TypeScript cannot resolve a non-literal module specifier.
    const promise = (import(url) as Promise<unknown>)
      .then((mod: unknown) => {
        const m = mod as WasmWebModule;
        if (typeof m.default !== "function") {
          throw new Error(
            `Cairn wasm glue at ${url} has no default export (init)`,
          );
        }
        if (typeof m.CairnSocket !== "function") {
          throw new Error(
            `Cairn wasm glue at ${url} has no CairnSocket export`,
          );
        }
        // Run the wasm init; resolves once wasm bytes are instantiated.
        return Promise.resolve(m.default()).then(() => m.CairnSocket);
      })
      .catch((err: unknown) => {
        // Drop the cache so the next connect() can retry from scratch.
        if (this.wasmPromise === promise) {
          this.wasmPromise = null;
        }
        throw err;
      });
    this.wasmPromise = promise;
    return promise;
  }
}
