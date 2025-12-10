import Foundation

public struct ByteRingBuffer: Sendable {
    private var storage: [UInt8]
    private var head: Int = 0
    private var tail: Int = 0
    private var count: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be positive")
        storage = Array(repeating: 0, count: capacity)
    }

    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == storage.count }
    public var capacity: Int { storage.count }
    public var length: Int { count }

    @discardableResult
    public mutating func push(_ value: UInt8) -> Bool {
        guard !isFull else { return false }
        storage[tail] = value
        tail = (tail + 1) % storage.count
        count += 1
        return true
    }

    public mutating func pop() -> UInt8? {
        guard !isEmpty else { return nil }
        let value = storage[head]
        head = (head + 1) % storage.count
        count -= 1
        return value
    }

    public mutating func clear() {
        head = 0
        tail = 0
        count = 0
    }
}
