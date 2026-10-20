import Foundation

// Fast scans for line feeds in ASCII bodies. One call to memchr for each line costs more than reading the bytes,
// so blocks of bytes are compared 16 at a time.
internal enum PLYLineFeeds {
    static func count(in bytes: UnsafeRawBufferPointer, _ range: Range<Int>) -> Int {
        let base = bytes.baseAddress.unsafelyUnwrapped
        var total = 0
        var offset = range.lowerBound
        let lineFeed = SIMD16<UInt8>(repeating: 0x0A)
        let zero = SIMD16<UInt8>(repeating: 0)
        let one = SIMD16<UInt8>(repeating: 1)
        while range.upperBound - offset >= 16 {
            // Lane sums fit in UInt8 for 255 blocks.
            var sums = zero
            var blocks = 0
            while blocks < 255, range.upperBound - offset >= 16 {
                let block = base.loadUnaligned(fromByteOffset: offset, as: SIMD16<UInt8>.self)
                sums &+= zero.replacing(with: one, where: block .== lineFeed)
                offset += 16
                blocks += 1
            }
            total += sums.indices.reduce(0) { $0 + Int(sums[$1]) }
        }
        while offset < range.upperBound {
            if base.load(fromByteOffset: offset, as: UInt8.self) == 0x0A {
                total += 1
            }
            offset += 1
        }
        return total
    }

    // The offset after `lineCount` lines from `start`, as `PLYReader.endOfLines(count:from:)` gives: each line ends
    // after its line feed, and a last line with no line feed ends one byte after the end of the data.
    static func end(ofLines lineCount: Int, in bytes: UnsafeRawBufferPointer, from start: Int) -> Int {
        let blockSize = 1 << 16
        var offset = start
        var remaining = lineCount
        // Skip whole blocks that have fewer line feeds than are needed.
        while remaining > 0, bytes.count - offset > blockSize {
            let lineFeeds = count(in: bytes, offset..<(offset + blockSize))
            guard lineFeeds < remaining else {
                break
            }
            remaining -= lineFeeds
            offset += blockSize
        }
        let base = bytes.baseAddress.unsafelyUnwrapped
        while remaining > 0, offset < bytes.count {
            let newline = memchr(base + offset, 0x0A, bytes.count - offset)
            offset = newline.map { UnsafeRawPointer($0) - base } ?? bytes.count
            offset += 1
            remaining -= 1
        }
        return offset
    }
}
