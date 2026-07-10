// swift-tools-version: 6.0
//
// bltusb Phase-2 privileged helper — SwiftPM package.
//
// This package `swift build`s cleanly with the Command Line Tools Swift
// toolchain (no Xcode, no signing identity required). It is the *skeleton* of
// the SRAA §3 three-layer design:
//
//   bltusb-helperd    — root XPC daemon (SMAppService)     [target: executable]
//   BltusbProtocol    — the 4-op XPC contract + validators [target: library]
//   BltusbClientLib   — unprivileged client library        [target: library]
//   bltusb-client     — a thin CLI over BltusbClientLib     [target: executable]
//
// Everything that requires a Developer ID certificate, notarization, Full Disk
// Access (PPPC), or actually shelling out to root `anylinuxfs` is behind a
// clearly-marked `// TODO(signing/deploy)` and is *stubbed so it still compiles*.
// See docs/PHASE2-HELPER-PLAN.md for the build/sign/deploy blockers.
import PackageDescription

let package = Package(
    name: "bltusb-helper",
    platforms: [
        // XPC audit-token peer validation + SMAppService require macOS 13+.
        .macOS(.v13)
    ],
    targets: [
        // Pure-Swift shared contract + validators. No platform capabilities,
        // so its unit tests run with `swift test` under the CLT toolchain.
        .target(
            name: "BltusbProtocol"
        ),
        // C shim vending the xpc audit-token SPI (not in the public XPC module).
        .target(
            name: "CXPCShim"
        ),
        .executableTarget(
            name: "bltusb-helperd",
            dependencies: ["BltusbProtocol", "CXPCShim"]
        ),
        .target(
            name: "BltusbClientLib",
            dependencies: ["BltusbProtocol"]
        ),
        .executableTarget(
            name: "bltusb-client",
            dependencies: ["BltusbClientLib", "BltusbProtocol"]
        ),
        .testTarget(
            name: "BltusbProtocolTests",
            dependencies: ["BltusbProtocol"]
        ),
    ]
)
