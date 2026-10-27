// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SquealerKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SquealerKit", targets: ["SquealerKit"]),
    ],
    targets: [
        .target(name: "SquealerKit"),
        .testTarget(name: "SquealerKitTests", dependencies: ["SquealerKit"]),
    ]
)
