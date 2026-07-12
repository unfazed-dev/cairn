// CairnSmoke — minimal iOS app that exercises the UniFFI-generated CairnClient
// against the real cairn-client + cairn-core + rusqlite stack linked from the
// Rust sim staticlib. Mirrors the offline smoke path in
// sdk/cairn_swift/src/lib.rs (`cairn_client_offline_connect_query_round_trip`)
// and the sibling SDKs' round-trip checks (cairn_node, cairn_tauri).
//
// This file is compiled INTO the same Swift module as the UniFFI-generated
// `cairn_swift.swift` (added to the target's sources via project.yml), so the
// `CairnClient` symbol is visible without a module import. The C FFI module
// `cairn_swiftFFI` (modulemap + header in `../../swift-sources/`) is exposed
// via the target's HEADER_SEARCH_PATHS — the generated Swift file's
// `#if canImport(cairn_swiftFFI)` then resolves.
//
// ponytail: this is a smoke harness, not a shipping iOS app. It launches, runs
// the round-trip on a background queue, prints a single delimited SUCCESS line
// to stdout, and `exit(0)`s. The upgrade path is the real SDK's iOS demo app.

import Foundation
import UIKit

final class SmokeAppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Run the smoke off the main run loop so UIApplication's main loop has
        // been initialized before we tear the process down with exit(0).
        DispatchQueue.global(qos: .userInitiated).async {
            Smoke.run()
        }
        return true
    }
}

enum Smoke {
    static func run() {
        // Marker line — anything we emit AFTER this is part of the test output.
        print("[cairn-smoke] BEGIN iPhone-17-sim round-trip")

        do {
            // Construct the handle. URL/token are unused offline (no subscribe
            // loop is wired — see src/lib.rs `connect()`). `:memory:` gives an
            // ephemeral SQLite store so the test is hermetic.
            let client = try CairnClient(
                url: "ws://localhost:0",
                token: nil,
                dbPath: ":memory:"
            )
            print("[cairn-smoke] constructed CairnClient")

            // Open the local SQLite store + build the SyncClient. No network.
            try client.connect()
            print("[cairn-smoke] connect() ok")

            // Offline read — same SELECT the Rust test in lib.rs asserts.
            let rowsJson = try client.query(sql: "SELECT 1 AS one")
            print("[cairn-smoke] query() rows=\(rowsJson)")

            // Checkpoint read — proves the durable LSN accessor survives the
            // FFI boundary too.
            let lsn = try client.checkpoint()
            print("[cairn-smoke] checkpoint() lsn=\(lsn)")

            print("[cairn-smoke] SUCCESS")
        } catch {
            print("[cairn-smoke] FAIL: \(error)")
        }

        // Terminate the process so simctl launch returns and the harness can
        // capture the full stdout. (Foundation.exit is the polite form; for
        // iOS we drop to the C function.)
        exit(0)
    }
}

// UIApplicationMain/UIApplicationAdaptor shims — keep the file self-contained
// (no @main attribute, which SwiftUI's App protocol would otherwise drive).
_ = UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(SmokeAppDelegate.self)
)
