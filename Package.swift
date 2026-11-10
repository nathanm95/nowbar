// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NowBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NowBar",
            path: "Sources/NowBar"
        )
    ]
)
