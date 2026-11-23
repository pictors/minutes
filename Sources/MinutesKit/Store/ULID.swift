import Foundation

/// ULID（26 文字、Crockford Base32、先頭 48 bit がミリ秒時刻）。meetings.id 等に使う（SPEC §7.1）。
public enum ULID {
    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate(date: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970) * 1000)
        for index in 0..<6 {
            bytes[index] = UInt8((milliseconds >> (8 * UInt64(5 - index))) & 0xFF)
        }
        for index in 6..<16 {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return encode(bytes)
    }

    /// 128 bit を 26 文字にする（先頭に 2 bit のゼロを詰めて 130 bit = 26 × 5 bit）。
    static func encode(_ bytes: [UInt8]) -> String {
        var output = ""
        output.reserveCapacity(26)
        var buffer: UInt32 = 0
        var bitCount = 2
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                let index = Int((buffer >> UInt32(bitCount - 5)) & 0x1F)
                output.append(alphabet[index])
                bitCount -= 5
                buffer &= (1 << UInt32(bitCount)) - 1
            }
        }
        return output
    }

    /// 先頭 10 文字から生成時刻を復元する。
    public static func timestamp(of ulid: String) -> Date? {
        guard ulid.count == 26 else { return nil }
        var value: UInt64 = 0
        for character in ulid.prefix(10) {
            guard let index = alphabet.firstIndex(of: Character(character.uppercased())) else { return nil }
            value = (value << 5) | UInt64(index)
        }
        return Date(timeIntervalSince1970: Double(value) / 1000)
    }
}
