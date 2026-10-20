import Dispatch
import Foundation

internal enum PLYParallel {
    // Runs `body` on parts of `0..<count` on all cores. Each part must write only its own records. If any part
    // throws, `body` runs again on the whole range on this thread, so the error is the one for the first record that
    // fails, as in a serial read.
    static func forEachChunk(count: Int, minimumChunkSize: Int, _ body: (Range<Int>) throws -> Void) throws {
        let chunkCount = min(ProcessInfo.processInfo.activeProcessorCount, count / max(minimumChunkSize, 1))
        guard chunkCount > 1 else {
            try body(0..<count)
            return
        }
        let failures = UnsafeMutableBufferPointer<Bool>.allocate(capacity: chunkCount)
        defer { failures.deallocate() }
        failures.initialize(repeating: false)
        withoutActuallyEscaping(body) { body in
            // The parts write disjoint memory, and `concurrentPerform` returns after every part ends.
            let shared = UncheckedSendable(value: (body: body, failures: failures))
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunk in
                // Balanced parts. Rounding the part size up instead can give empty or reversed ranges at the end.
                let range = (chunk * count / chunkCount)..<((chunk + 1) * count / chunkCount)
                do {
                    try shared.value.body(range)
                } catch {
                    shared.value.failures[chunk] = true
                }
            }
        }
        if failures.contains(true) {
            try body(0..<count)
        }
    }

    private struct UncheckedSendable<Value>: @unchecked Sendable {
        var value: Value
    }
}
