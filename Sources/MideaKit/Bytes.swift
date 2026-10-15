import Foundation

extension Array where Element == UInt8 {
    /// Lowercase hex string.
    public var hex: String { map { String(format: "%02x", $0) }.joined() }

    public init?(hex: String) {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }

    public var data: Data { Data(self) }
}

extension Data {
    public var bytes: [UInt8] { [UInt8](self) }
    public var hex: String { bytes.hex }
    public init?(hex: String) {
        guard let b = [UInt8](hex: hex) else { return nil }
        self = Data(b)
    }
}

@inline(__always) func le16(_ lo: UInt8, _ hi: UInt8) -> UInt16 { UInt16(lo) | (UInt16(hi) << 8) }
@inline(__always) func be16(_ hi: UInt8, _ lo: UInt8) -> UInt16 { (UInt16(hi) << 8) | UInt16(lo) }

func leBytes(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
}

func beBytes(_ value: UInt64, count: Int) -> [UInt8] {
    (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
}

func leUInt64(_ bytes: ArraySlice<UInt8>) -> UInt64 {
    var v: UInt64 = 0
    for (i, b) in bytes.enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
    return v
}
