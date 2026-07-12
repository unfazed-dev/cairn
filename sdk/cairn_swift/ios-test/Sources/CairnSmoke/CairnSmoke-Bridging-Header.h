// CairnSmoke bridging header.
//
// ponytail: the UniFFI-generated `cairn_swift.swift` does
// `#if canImport(cairn_swiftFFI) import cairn_swiftFFI` to pull in the C FFI
// types (RustBuffer / ForeignBytes / RustCallStatus) and the per-crate
// `ffi_cairn_swift_*` / `uniffi_cairn_swift_checksum_*` function decls.
// Getting a stand-alone `.modulemap` discoverable to Xcode's clang importer
// (so that `canImport` returns true at compile time) is fiddly — the canonical
// low-friction alternative is a bridging header that `#import`s the same
// `cairn_swiftFFI.h`. Xcode auto-loads the bridging header into every Swift
// file in the target, so every C symbol the bindings reference becomes a
// top-level identifier in Swift — no module qualification, no modulemap
// plumbing. `canImport(cairn_swiftFFI)` evaluates false (no formal module),
// the conditional `import` is skipped, and the symbols still resolve.
//
// HEADER_SEARCH_PATHS includes `$(SRCROOT)/../swift-sources`, so the bare
// `#import "cairn_swiftFFI.h"` resolves to the UniFFI-emitted header.

#import "cairn_swiftFFI.h"
