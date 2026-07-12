// Cairn Swift shim — re-export entry point.
//
// The UniFFI-generated Swift (`cairn_swift.swift`, produced by
// `uniffi-bindgen generate --library ../target/debug/libcairn_swift.dylib
// --language swift --out-dir ../swift-sources/`) defines the `CairnClient`
// class on the Swift side. This file is a placeholder so `Sources/Cairn/` is
// non-empty for the SPM `.target(name: "Cairn", path: "Sources/Cairn")`
// declaration in Package.swift; the real Swift surface lives in the generated
// file and is wired in by the binary-target increment (see Package.swift
// ponytail).

import Foundation

/// Marker for the scaffold: the generated bindings are not yet compiled into
/// this target. Once `swift-sources/cairn_swift.swift` is added as a source,
/// callers use `CairnClient` directly.
public enum CairnSDK {
    public static let name = "cairn-swift"
    public static let isLinked = false
}
