// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "axcli",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "axcli", path: "Sources/axcli")
    ]
)
