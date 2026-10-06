import CryptoKit
import Foundation

enum PipelineFingerprint {
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encoded<T: Encodable>(_ value: T) throws -> String {
        hash(try JSONCoding.encoder(pretty: false).encode(value))
    }

    static func file(_ url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 根拠は DB の安定 ID。生成時のモデルと入力を成果物に結び付ける。
struct SummaryArtifact: Codable {
    var summary: MinutesSummary
    var model: String
    var inputFingerprint: String
}
