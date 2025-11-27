// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macrec",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "macrec", targets: ["macrec"])
    ],
    targets: [
        .executableTarget(name: "macrec")
    ]
)
