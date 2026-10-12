// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Clipline",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .executableTarget(name: "Clipline", path: "Sources/Clipline", exclude: ["Resources"])
    ]
)
