import Foundation
import os

extension Logger {
    private static let subsystem = "libdivecomputer-swift"

    static let shearwater = Logger(subsystem: subsystem, category: "shearwater")
    static let simulated = Logger(subsystem: subsystem, category: "simulated")
    static let bluetooth = Logger(subsystem: subsystem, category: "bluetooth")
}
