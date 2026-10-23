// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SmartDisk",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "slim-helper", targets: ["SlimHelper"]),
        .executable(name: "SmartDisk", targets: ["SmartDisk"]),
    ],
    targets: [
        // Wraps PDFKit, Vision and Foundation Models for the Rust core.
        .executableTarget(name: "SlimHelper", path: "Sources/SlimHelper"),
        // Menu bar + main window.
        .executableTarget(name: "SmartDisk", path: "Sources/SmartDisk"),
        .testTarget(name: "SmartDiskTests", dependencies: ["SmartDisk"]),
    ]
)
