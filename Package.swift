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
    targets: [
        .target(
            name: "DiveComputerSwift"
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
