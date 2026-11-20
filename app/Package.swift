// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ChipScope",
    platforms: [.macOS(.v14)],
    targets: [
        // Private counters (IOReport), the SMC user client and HID temperature sensors, in C.
        .target(
            name: "CChip",
            path: "Sources/CChip",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        // Collectors + model shared by the app and the self-check.
        .target(
            name: "ChipCore",
            dependencies: ["CChip"],
            path: "Sources/ChipCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "ChipScope",
            dependencies: ["ChipCore"],
            path: "Sources/ChipScope",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        // `swift run ChipCheck`: unit checks + a live collector smoke test (no XCTest in the CLT).
        .executableTarget(
            name: "ChipCheck",
            dependencies: ["ChipCore"],
            path: "Sources/ChipCheck"
        ),
    ]
)
