// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mx",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "mx", path: "Sources/mx")
    ]
)
