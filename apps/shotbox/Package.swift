// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShotBox",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ShotBox", targets: ["ShotBox"])
    ],
    targets: [
        .executableTarget(name: "ShotBox", path: "Sources/ShotBox")
    ]
)
