// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WinlinkKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WinlinkKit", targets: ["WinlinkKit"]),
        .executable(name: "winlinkkit-cli", targets: ["winlinkkit-cli"]),
    ],
    targets: [
        .target(
            name: "WinlinkKit"
        ),
        .executableTarget(
            name: "winlinkkit-cli",
            dependencies: ["WinlinkKit"]
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
