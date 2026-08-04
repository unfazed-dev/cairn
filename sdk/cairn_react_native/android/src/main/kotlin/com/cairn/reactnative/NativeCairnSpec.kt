package com.cairn.reactnative

import com.facebook.react.bridge.Callback
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.module.annotations.ReactModule

/**
 * The Codegen-equivalent Spec for the `NativeCairn` TurboModule.
 *
 * `@react-native/codegen` would emit this abstract class from
 * `src/NativeCairn.ts` (codegenConfig `name = "NativeCairn"`) at native-build
 * time inside a host RN app. It is hand-mirrored here verbatim so this
 * standalone library module builds + unit-tests WITHOUT needing the codegen
 * gradle task to run: the concrete override in [CairnTurboModule] is what
 * RN's runtime `@ReactMethod` annotation scanner reads, and the
 * `@ReactModule(name = ...)` on this class binds the JS-side
 * `TurboModuleRegistry.getEnforcing("NativeCairn")` lookup to the concrete
 * implementation.
 *
 * Method-by-method (spec → UniFFI `uniffi.cairn_kotlin.CairnClient`):
 *   connect(url, token, dbPath) → CairnClient(url, token, dbPath) + .connect()
 *   subscribe(table)            → .subscribe(table)
 *   write(table, op, pk, pj)    → .write(table, op, pk, payloadJson)  (ULong → JS Double)
 *   query(sql)                  → .query(sql)                          (JSON-rows String)
 *   checkpoint()                → .checkpoint()                        (ULong → JS Double)
 *   setToken(token)             → .setToken(token)  (ADR-0029 #3; Option<String> ↔ Kotlin String?)
 *   signOut()                   → .signOut()        (ADR-0029 wipe; abort→await→clear→drop→clear-token)
 *   watchChanges(table, cb)     → .subscribe(table) + .watch(table, sink)  (RN Callback wrapped in a
 *                              UniFFI `SnapshotSink` adapter — the Kotlin mirror of iOS's CairnSnapshotSink.
 *                              cb is a `Callback` (Codegen mapping of a JS `(rowsJson) => void` param) — the
 *                              native impl retains it and invokes it on the JS thread with the INITIAL
 *                              snapshot, then after every applied change.)
 *   unwatchChanges(table)       → nil the retained Callback. BINDING FLOOR: cairn_kotlin has no stop_watch
 *                              (the Rust pump is tied to the session). So this stops DELIVERY to JS, not the
 *                              pump; the sink is retained until session end so UniFFI's handle can't dangle.
 *
 * `payloadJson: String?` mirrors UniFFI's `Option<String>`: `null` = None
 * (delete shape — no row image), a JSON string = Some(...). The Kotlin `?`
 * matches the TS spec's `string | null`.
 */
@ReactModule(name = NativeCairnSpec.NAME)
abstract class NativeCairnSpec :
    ReactContextBaseJavaModule {
    /**
     * RN-bridge-facing constructor — the one RN's module registry uses to
     * instantiate the TurboModule inside a host app.
     */
    constructor(reactContext: ReactApplicationContext) : super(reactContext)

    /**
     * Test-facing no-arg constructor. `ReactApplicationContext` is abstract in
     * RN 0.79+ (instantiated only inside the React host infra), so on-device
     * instrumented tests construct the module without one. Safe because the
     * Spec methods never touch `getReactApplicationContext()` — they delegate
     * purely to the UniFFI `CairnClient` handle.
     */
    constructor() : super()

    override fun getName(): String = NAME

    abstract fun connect(url: String, token: String?, dbPath: String, promise: Promise)
    abstract fun subscribe(table: String, promise: Promise)
    abstract fun write(
        table: String,
        op: String,
        pk: String,
        payloadJson: String?,
        promise: Promise,
    )
    abstract fun query(sql: String, promise: Promise)
    abstract fun checkpoint(promise: Promise)
    abstract fun setToken(token: String?, promise: Promise)
    abstract fun signOut(promise: Promise)
    abstract fun watchChanges(table: String, onSnapshot: Callback, promise: Promise)
    abstract fun unwatchChanges(table: String, promise: Promise)

    companion object {
        const val NAME = "NativeCairn"
    }
}
