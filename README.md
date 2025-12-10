# libdivecomputer-swift

A pure Swift library for communicating with dive computers, heavily inspired by [libdivecomputer](https://www.libdivecomputer.org) but built from the ground up for modern Apple platforms (macOS/iOS) with a focus on Bluetooth capabilities.

> [!NOTE]
> This project is currently under **rapid development**. APIs are subject to change.

## Overview

`libdivecomputer-swift` aims to provide a native Swift interface for downloading dive logs and interacting with dive computers. Unlike the original C-based libdivecomputer, this library leverages modern Swift features, including:

- **Swift Concurrency**: Fully async/await API.
- **CoreBluetooth**: Native support for Bluetooth Low Energy (BLE) devices.
- **Type Safety**: Swift's strong type system for parsing and data handling.

## Requirements

- Swift 6.0+
- iOS 17.0+
- macOS 15.0+

## Demos & Examples

The repository contains examples to help you get started:

### Command Line Interface (CLI)

A CLI tool demonstrating how to interact with dive computers (currently focused on Shearwater devices).

- **Source**: [`Sources/ShearwaterCLI`](Sources/ShearwaterCLI)

### SwiftUI Demo

A SwitUI view demonstrating integration within an iOS/macOS application.

- **Source**: [`Sources/DiveComputerSwift/Shearwater/ShearwaterDemoView.swift`](Sources/DiveComputerSwift/Shearwater/ShearwaterDemoView.swift)

## Installation

### Swift Package Manager

Add `libdivecomputer-swift` to your project by adding it as a dependency in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/divehub/libdivecomputer-swift.git", branch: "main")
]
```

## Contributing

Contributions are welcome! Please feel free to verify the status of the project or open issues for discussion.
