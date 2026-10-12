// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clipline",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .executableTarget(name: "Clipline", path: "Sources/Clipline", exclude: ["Resources"]),
        .testTarget(name: "CliplineTests", dependencies: ["Clipline"], path: "Tests/CliplineTests"),
        // Drive the built app like a person would. See Tests/CliplineE2ETests/Harness.swift.
        .testTarget(name: "CliplineE2ETests", path: "Tests/CliplineE2ETests"),
    ]
)
