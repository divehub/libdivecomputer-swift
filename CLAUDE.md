# libdivecomputer-swift Engineering Context

## Project Goal
A Swift library for communicating with dive computers via Bluetooth Low Energy (BLE).

## Architecture
- **Type**: Swift Package.
- **Frameworks**: `CoreBluetooth`.

## Scope
- **Scanning**: Discover supported dive computers.
- **Connection**: Handle BLE connection and service discovery.
- **Protocol**: Implementation of specific dive computer transfer protocols (downloading logs, reading settings).

## Development Guidelines
- **Hardware**: Testing often requires actual hardware. When simulating or mocking, be explicit.
- **Concurrency**: Likely uses `async/await` and Actors to manage Bluetooth state, similar to `libdna`.
- **Bluetooth**: Be mindful of CoreBluetooth delegates and state restoration if applicable.

## Build & Test
- **Tooling**: Use `swift test` for running unit tests.
- **UI Interaction**: None. This is a logic/communication library.
