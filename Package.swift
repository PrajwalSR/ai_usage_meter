// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIUsageMeter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIUsageMeter",
            path: "Sources/AIUsageMeter"
        )
    ]
)
