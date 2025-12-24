// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DiveComputerSwift",
    platforms: [
        .macOS(.v15),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "DiveComputerSwift",
            targets: ["DiveComputerSwift"]
        ),
        .executable(
            name: "shearwater-cli",
            targets: ["ShearwaterCLI"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.1")
    ],
    targets: [
        .target(
            name: "DiveComputerSwift",
            dependencies: ["Yams"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ShearwaterCLI",
            dependencies: ["DiveComputerSwift"]
        ),
        .testTarget(
            name: "DiveComputerSwiftTests",
            dependencies: ["DiveComputerSwift"]
        ),
    ]
)
