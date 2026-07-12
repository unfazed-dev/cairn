# ADR-0020: React Native SDK via Turbo Native Module over UniFFI (not the WASM JS core)

- **Status:** Accepted (shipped — Android emu live-E2E verified)
- **Date:** 2026-07-12

## Context

Cairn ships a JS core (`@cairn/web` over `cairn-ffi-wasm`) for the browser. The
obvious "cheap" path for a React Native SDK would be to reuse that JS core —
mirroring how PowerSync's `@powersync/react-native` shares `@powersync/js`.

It does not work. PowerSync's JS core is **pure TypeScript**; Cairn's is
**WebAssembly**. RN's default engine (Hermes) does not ship
`global.WebAssembly` in any release through RN 0.84 (Feb 2026): the official
RN 0.84 blog has zero WebAssembly/WASM mentions, and Hermes issue #429 (opened
2020-12) is still open with no linked PR. Maintainer guidance is that JS-only
WASM polyfills are "bound to be slow" and that a JSC detour is "not
future-proofed." So `@cairn/web`'s WASM module cannot run inside RN.

## Decision

`sdk/cairn_react_native` is a thin **TypeScript facade** (mirroring `@cairn/web`'s
public API: `connect` / `subscribe` / `query` / `write` / `checkpoint`) backed by
a **Codegen Turbo Native Module** that calls the already-shipped `cairn_kotlin`
(Android) and `cairn_swift` (iOS) UniFFI bindings. No new Rust: the native
modules reuse the existing `libcairn_kotlin.so` / Swift staticlib + their
generated foreign bindings wholesale. `subscribe()` polls `query()` (same shape
as cairn_swift / cairn_kotlin); a UniFFI callback event-emitter is a documented
Phase-2 polish, not a launch blocker.

The TS facade is kept byte-identical to `@cairn/web`'s surface so a future
Hermes-WASM pivot (if #429 ever closes) is a backend-only swap with zero
public-API churn.

## Alternatives considered

- **WASM JS core in RN** — rejected: Hermes has no WASM (Context).
- **Direct JSI C++ binding** (cbindgen + hand-rolled `cxx`, margelo-style) —
  rejected for now: the UniFFI↔TurboModule hop overhead is microsecond-scale,
  dominated by WS + SQLite I/O, so the perf win is marginal; and it needs
  hand-written `unsafe` C++ that breaks the workspace `forbid(unsafe_code)` and
  the "reuse existing bindings" rule. Defer until a measurement demands it.
- **Pure-TS re-implementation of the sync engine** (the PowerSync .NET/RN
  approach) — rejected: abandons the Rust core + the throughput moat.

## Consequences

- One Rust interface (`CairnClient`) → four foreign bindings (Swift, Kotlin, C#
  via UniFFI-CS per ADR-0015's strategy, and now RN-TurboModule-over-Kotlin/Swift).
  Consistent with ADR-0015's "thin FFI bridge per platform."
- Cairn Rust stays `forbid(unsafe_code)`; the RN Codegen's own JSI `unsafe`
  lives in RN's generated code, not Cairn's hand-written source (the ADR-0015
  machine-generated-FFI exception).
- iOS TurboModule is a fast-follow (cairn_swift is sim-E2E-proven, so the
  pieces exist); Android is emu-live-E2E-verified (`PUSH_OK` + `ECHO_OK`).
- Plan: `docs/plans/sdk-parity-final-three.md`.
