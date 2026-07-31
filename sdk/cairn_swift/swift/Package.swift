// swift-tools-version:5.9
//
// Cairn Swift Package — wraps the UniFFI-generated `cairn_swift.swift` + the
// Rust staticlib (`libcairn_swift.a`) produced by `cargo build --release`.
//
// SCOPE (scaffold): the UniFFI-generated Swift is verified by
// `swiftc -typecheck -I swift-sources swift-sources/cairn_swift.swift` — see
// the parent README/ponytail notes in sdk/cairn_swift/src/lib.rs. SPM
// `.binaryTarget` linking of the `.a` (and the `.xcframework` for iOS) is the
// NEXT increment; this Package.swift declares the target shape a future
// xcframework would slot into.
//
// ponytail: this Package currently exposes Cairn as a regular target whose
// source is the hand-written `AsyncStream`-based `watch(table:)` facade in
// `Sources/Cairn/Cairn.swift` (built on the UniFFI-generated
// `swift-sources/cairn_swift.swift`, which declares `CairnClient` +
// `SnapshotSink`). The generated sources + `cairn_swiftFFI` modulemap are NOT
// wired into this SPM target yet — `swiftc -typecheck …` (see the README gate)
// is the verification floor; `swift build` here will NOT resolve
// `CairnClient`/`SnapshotSink` until the binary-target increment lands. To ship,
// replace the `.target` with a `.binaryTarget(path: "../xcframework/Cairn.xcframework")`
// once the xcframework is built (cargo build --release for macos + ios targets,
// then xcodebuild -create-xcframework) and add the generated `.swift` +
// modulemap as a co-compiled source set.

import PackageDescription

let package = Package(
    name: "Cairn",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "Cairn", targets: ["Cairn"]),
    ],
    targets: [
        // The UniFFI-generated Swift sources live in ../swift-sources/ after
        // `uniffi-bindgen generate`. The Sources/Cairn/ shim re-exports them
        // so SPM sees a single module. The C FFI module
        // (cairn_swiftFFI.modulemap + .h) must be reachable via -I — wired in
        // by the binary-target increment below when the .a ships.
        .target(
            name: "Cairn",
            path: "Sources/Cairn"
        ),
    ]
)
