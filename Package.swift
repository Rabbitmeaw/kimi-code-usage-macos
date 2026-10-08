// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KimiUsage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "KimiUsage", targets: ["KimiUsage"]),
        .executable(name: "KimiUsageWatcher", targets: ["KimiUsageWatcher"])
    ],
    targets: [
        .executableTarget(name: "KimiUsage"),
        .executableTarget(name: "KimiUsageWatcher")
    ]
)
