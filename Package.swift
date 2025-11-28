// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macrec",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MacrecCore", targets: ["MacrecCore"]),
        .executable(name: "macrec", targets: ["macrec"]),
        .executable(name: "MacrecUI", targets: ["MacrecUI"])
    ],
    targets: [
        .target(name: "MacrecCore"),
        .executableTarget(
            name: "macrec",
            dependencies: ["MacrecCore"]
        ),
        .executableTarget(
            name: "MacrecUI",
            dependencies: ["MacrecCore"]
        )
    ]
)
