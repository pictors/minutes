import Foundation

/// multipart/form-data のエンコーダ（ElevenLabs / OpenAI の音声アップロード用）。
/// 音声ファイルは `addFile(url:)` で参照だけ持ち、`write(to:)` でディスクに流し込むので、
/// 60 分の WAV（約 115 MB）を multipart 化してもメモリ上に 2 重に持たない。
public struct MultipartFormData: Sendable {
    private enum Part: Sendable {
        case bytes(Data)
        case file(URL)
    }

    public let boundary: String
    private var parts: [Part] = []

    public init(boundary: String = "minutes-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append(value)
        body.append("\r\n")
        parts.append(.bytes(body))
    }

    public mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        parts.append(.bytes(fileHeader(name: name, filename: filename, contentType: contentType)))
        var body = data
        body.append("\r\n")
        parts.append(.bytes(body))
    }

    /// ファイルを参照で追加する。内容は `write(to:)` / `encoded()` の時点で読む。
    public mutating func addFile(name: String, filename: String, contentType: String, url: URL) {
        parts.append(.bytes(fileHeader(name: name, filename: filename, contentType: contentType)))
        parts.append(.file(url))
        parts.append(.bytes(Data("\r\n".utf8)))
    }

    private func fileHeader(name: String, filename: String, contentType: String) -> Data {
        var header = Data()
        header.append("--\(boundary)\r\n")
        header.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        header.append("Content-Type: \(contentType)\r\n\r\n")
        return header
    }

    private var closing: Data { Data("--\(boundary)--\r\n".utf8) }

    /// 終端境界を付けた完成形の body を返す（小さなリクエストとテスト用）。
    public func encoded() throws -> Data {
        var out = Data()
        for part in parts {
            switch part {
            case let .bytes(data): out.append(data)
            case let .file(url): out.append(try Data(contentsOf: url))
            }
        }
        out.append(closing)
        return out
    }

    /// body をファイルに書く（`URLSession.upload(for:fromFile:)` 用）。ファイル参照は 1 MiB ずつコピーする。
    public func write(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        for part in parts {
            switch part {
            case let .bytes(data):
                try output.write(contentsOf: data)
            case let .file(source):
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                    try output.write(contentsOf: chunk)
                }
            }
        }
        try output.write(contentsOf: closing)
    }

    /// 一時ファイルに書き出し、その URL を返す。呼び出し側が送信後に削除する。
    public func writeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-upload-\(UUID().uuidString).multipart")
        try write(to: url)
        return url
    }

    /// 拡張子から MIME type を推定する。
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg", "oga": return "audio/ogg"
        case "webm": return "audio/webm"
        case "aiff", "aif": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }
}

extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
