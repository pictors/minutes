import Foundation

/// WAV の close 前に終了した場合、PCM データは残っていてもサイズ欄が未確定なことがある。
/// 自分で生成する mono / 16 kHz / 16-bit PCM だけを対象に、元ファイルを残してヘッダを復旧する。
enum InterruptedWAVRecovery {
    static func repair(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var bytes = try Data(contentsOf: url)
        guard bytes.count >= 44, bytes.count <= Int(UInt32.max),
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else { return false }
        func uint(_ index: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(bytes[index + $1]) << (8 * $1) }
        }
        var offset = 12
        var validPCM = false
        while offset + 8 <= bytes.count {
            let kind = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = uint(offset + 4, 4)
            let start = offset + 8
            if kind == "fmt ", size >= 16, start + 16 <= bytes.count {
                validPCM = uint(start, 2) == 1 && uint(start + 2, 2) == 1 && uint(start + 4, 4) == 16_000 && uint(start + 12, 2) == 2 && uint(start + 14, 2) == 16
            }
            if kind == "data" {
                // 完成済みファイルは変更しない。破損サイズを外部メタデータから推測しない。
                guard validPCM, size == 0 || size > bytes.count - start else { return false }
                let actual = (bytes.count - start) / 2 * 2
                guard actual > 0 else { return false }
                bytes = bytes.prefix(start + actual)
                for (position, value) in [(4, bytes.count - 8), (offset + 4, actual)] {
                    var little = UInt32(value).littleEndian
                    withUnsafeBytes(of: &little) { bytes.replaceSubrange(position..<(position + 4), with: $0) }
                }
                let backup = url.appendingPathExtension("interrupted")
                if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: url, to: backup) }
                try bytes.write(to: url, options: .atomic)
                return true
            }
            guard size <= bytes.count - start else { return false }
            offset = start + size + size % 2
        }
        return false
    }
}
