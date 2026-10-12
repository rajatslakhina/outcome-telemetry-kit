// swift-tools-version:6.0
import PackageDescription

// Library-only package. There is deliberately no executable or app target here:
// the runnable demo is a separate Xcode project in its own repository
// (outcome-telemetry-kit-demo-app) that consumes this package by release tag.
let package = Package(
    name: "OutcomeTelemetry",
    // Only platforms CI actually builds are declared. The core module has no
    // platform-specific code and also builds and tests on Linux.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OutcomeTelemetry", targets: ["OutcomeTelemetry"]),
        .library(name: "OutcomeTelemetryUI", targets: ["OutcomeTelemetryUI"]),
    ],
    targets: [
        .target(name: "OutcomeTelemetry"),
        .target(name: "OutcomeTelemetryUI", dependencies: ["OutcomeTelemetry"]),
        .testTarget(name: "OutcomeTelemetryTests", dependencies: ["OutcomeTelemetry"]),
    ]
)
