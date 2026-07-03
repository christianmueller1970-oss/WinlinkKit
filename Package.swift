// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WinlinkKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WinlinkKit", targets: ["WinlinkKit"])
    ],
    targets: [
        .target(
            name: "WinlinkKit"
        ),
        .testTarget(
            name: "WinlinkKitTests",
            dependencies: ["WinlinkKit"],
            resources: [
                .copy("Fixtures")
            ]
        ),
    ]
)
