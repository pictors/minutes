import Foundation
import MinutesKit

/// 端末の録音（Documents/Recordings/<client_id>/）。中身は upload.json（MinutesCloudUpload）と走のファイル（run-<n>.aac）、
/// 送るあいだだけの parts/（区切りと、録音を作る・complete の本文）。製品版の P4。
struct RecordingStore: Sendable {
    let root: URL

    static let standard = RecordingStore(root: URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory))

    /// upload.json を書き換えるのは、この鍵を持ったときだけ（録音する側と送る側が同じ記録を書く。古い写しで上書きしない）。
    static let lock = NSRecursiveLock()

    /// 記録をファイルから読み直して書き換え、すぐに書く（録音する側・送る側の両方がこれで書く）。
    @discardableResult
    func update<T>(clientId: String, _ body: (inout MinutesCloudUpload) throws -> T) throws -> T {
        try Self.lock.withLock {
            var upload = try load(clientId: clientId)
            let result = try body(&upload)
            try save(upload)
            return result
        }
    }

    func directory(for clientId: String) -> URL {
        root.appending(path: clientId, directoryHint: .isDirectory)
    }

    func partsDirectory(for clientId: String) -> URL {
        directory(for: clientId).appending(path: "parts", directoryHint: .isDirectory)
    }

    func runURL(_ upload: MinutesCloudUpload, _ run: MinutesCloudUpload.Run) -> URL {
        directory(for: upload.clientId).appending(path: run.fileName)
    }

    func partURL(clientId: String, part: MinutesCloudUpload.Part) -> URL {
        partsDirectory(for: clientId).appending(path: part.fileName)
    }

    func create(_ upload: MinutesCloudUpload) throws {
        try FileManager.default.createDirectory(at: partsDirectory(for: upload.clientId), withIntermediateDirectories: true)
        try upload.save(to: directory(for: upload.clientId))
    }

    func save(_ upload: MinutesCloudUpload) throws {
        try Self.lock.withLock { try upload.save(to: directory(for: upload.clientId)) }
    }

    func load(clientId: String) throws -> MinutesCloudUpload {
        try MinutesCloudUpload.load(from: directory(for: clientId))
    }

    /// 端末にある録音（新しい順）。
    func all() -> [MinutesCloudUpload] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { try? load(clientId: $0) }.sorted { $0.startedAt > $1.startedAt }
    }

    func delete(clientId: String) throws {
        let url = directory(for: clientId)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// 走のファイルの今の大きさ（走の番号 → バイト数）。
    func fileSizes(_ upload: MinutesCloudUpload) -> [Int: Int] {
        var sizes: [Int: Int] = [:]
        for run in upload.runs {
            let attributes = try? FileManager.default.attributesOfItem(atPath: runURL(upload, run).path)
            sizes[run.index] = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }
        return sizes
    }

    /// 送り終えた区切りと本文を消す（走のファイルは再生のために残す）。
    func removeParts(clientId: String) {
        try? FileManager.default.removeItem(at: partsDirectory(for: clientId))
    }
}
