import CryptoKit
import Foundation

/// 端末（iPhone・Watch）で録った 1 本の録音を、区切りで Pictors のサーバーへ上げるための記録（製品版の P4）。
/// 録音のフォルダに upload.json として置き、変わるたびに書き直す（アプリが落ちても、裏で起こされても、続きから上げる）。
///
/// - 録音は走（run）ごとに 1 つの ADTS の AAC ファイルに書き足していく。中断（電話・Siri）で走が分かれる。
///   書いている途中のファイルの先頭は、書き終えたファイルと同じバイト列なので（2026-11-22 の確認）、増えた分だけを区切りにできる。
///   サーバーは区切りを走と位置の順につないで 1 本にする（ADTS は前から足していくだけなので、つなげば元に戻る）。
/// - 区切りの境目はここで決めて記録する。上げ直し・ほかの経路（Watch から iPhone 経由）でも、同じ境目・同じバイト列で上げるので、
///   サーバーの同じ場所（parts/:run/:offset）に同じものが重なるだけになる。
/// - 区切りを切り出したときのバイト列の SHA-256 を覚えておき、走を閉じたあとのファイルと比べる。書き終えるときに前の部分が
///   書き換わっていたら（端末の符号化器が足すだけでなかったら）、その区切りを上げ直す（サーバーの音声は必ず閉じたファイルと同じになる）。
/// - 録音の ID（client_id）は端末で決める（サーバーで二重に作らない）。
public struct MinutesCloudUpload: Codable, Sendable, Equatable {
    /// 録音中に区切る大きさ（AAC 32 kbps で約 30 秒）
    public static let minimumPartBytes = 120_000
    /// 1 つの区切りの上限（約 17 分。回線が戻ったあとにまとめて上げるときも、1 回の送信を小さく保つ）
    public static let maximumPartBytes = 4_000_000
    public static let fileName = "upload.json"
    public static let contentType = "audio/aac"

    public struct Run: Codable, Sendable, Equatable {
        public var index: Int
        /// 録音のフォルダの中のファイル名
        public var fileName: String
        public var startedAt: Date
        /// 走を閉じた（これ以上書き足さない）
        public var finished: Bool
        /// 閉じた走の長さ（秒）
        public var durationSeconds: Double?

        public init(index: Int, fileName: String, startedAt: Date, finished: Bool = false, durationSeconds: Double? = nil) {
            self.index = index
            self.fileName = fileName
            self.startedAt = startedAt
            self.finished = finished
            self.durationSeconds = durationSeconds
        }
    }

    public struct Part: Codable, Sendable, Equatable, Hashable {
        public var run: Int
        public var offset: Int
        public var size: Int
        public var uploaded: Bool
        /// 切り出したときのバイト列の SHA-256（16 進）。まだ切り出していなければ nil
        public var sha256: String?

        public init(run: Int, offset: Int, size: Int, uploaded: Bool = false, sha256: String? = nil) {
            self.run = run
            self.offset = offset
            self.size = size
            self.uploaded = uploaded
            self.sha256 = sha256
        }

        /// 送るあいだだけ置く区切りのファイルの名前
        public var fileName: String { "part-\(run)-\(offset).aac" }
    }

    public var clientId: String
    /// "iphone" | "watch"
    public var source: String
    public var title: String?
    public var startedAt: Date
    public var timeZone: String
    /// "ja" | "en"。nil は自動
    public var language: String?
    /// サーバーの録音の ID（作ったあと）
    public var serverId: String?
    public var runs: [Run]
    public var parts: [Part]
    /// 録音を止めた（走はもう増えない）
    public var stopped: Bool
    /// サーバーが complete を受けた（処理が始まった）
    public var completed: Bool
    /// 最後の失敗（表示用。うまくいったら消す）
    public var lastError: String?

    public init(clientId: String, source: String, title: String? = nil, startedAt: Date, timeZone: String = TimeZone.current.identifier, language: String? = nil) {
        self.clientId = clientId
        self.source = source
        self.title = title
        self.startedAt = startedAt
        self.timeZone = timeZone
        self.language = language
        serverId = nil
        runs = []
        parts = []
        stopped = false
        completed = false
        lastError = nil
    }

    /// 端末で決める録音の ID（サーバーの client_id は 8〜100 文字）。
    public static func newClientID(source: String, date: Date = Date()) -> String {
        "\(source)-\(ULID.generate(date: date).lowercased())"
    }

    // MARK: 走

    /// 新しい走を始める（最初の録音と、中断のあとの再開）。書き込むファイルの名前を返す。
    @discardableResult
    public mutating func startRun(at date: Date) -> Run {
        let index = (runs.map(\.index).max() ?? -1) + 1
        let run = Run(index: index, fileName: "run-\(index).aac", startedAt: date)
        runs.append(run)
        return run
    }

    /// 走を閉じる。
    public mutating func finishRun(_ index: Int, durationSeconds: Double?) {
        guard let position = runs.firstIndex(where: { $0.index == index }) else { return }
        runs[position].finished = true
        runs[position].durationSeconds = durationSeconds
    }

    /// 録音を止める（閉じていない走があれば閉じる。長さは分からないまま）。
    public mutating func stop() {
        for position in runs.indices where !runs[position].finished {
            runs[position].finished = true
        }
        stopped = true
    }

    /// 走のあいだの録れていない時間（中断から再開まで）。会議の画面に出す。
    public var gaps: [DateInterval] {
        let ordered = runs.sorted { $0.index < $1.index }
        return zip(ordered, ordered.dropFirst()).compactMap { previous, next in
            guard let duration = previous.durationSeconds else { return nil }
            let end = previous.startedAt.addingTimeInterval(duration)
            return next.startedAt > end ? DateInterval(start: end, end: next.startedAt) : nil
        }
    }

    /// 録れた長さ（閉じた走の合計）。
    public var durationSeconds: Double? {
        let values = runs.compactMap(\.durationSeconds)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    // MARK: 区切り

    public func plannedBytes(run: Int) -> Int {
        parts.lazy.filter { $0.run == run }.reduce(0) { $0 + $1.size }
    }

    public var totalBytes: Int { parts.reduce(0) { $0 + $1.size } }

    public var pendingParts: [Part] { parts.filter { !$0.uploaded } }

    /// 走のファイルの今の大きさ（走の番号 → バイト数）から、新しい区切りを決めて足す。足した区切りを返す。
    /// 閉じていない走は minimumBytes 以上増えたときだけ区切り、半端は次に回す。閉じた走は残りをすべて区切る。どちらも maximumBytes ごとに分ける。
    @discardableResult
    public mutating func planParts(fileSizes: [Int: Int], minimumBytes: Int = MinutesCloudUpload.minimumPartBytes,
                                   maximumBytes: Int = MinutesCloudUpload.maximumPartBytes) -> [Part] {
        var added: [Part] = []
        for run in runs.sorted(by: { $0.index < $1.index }) {
            guard let size = fileSizes[run.index] else { continue }
            var planned = plannedBytes(run: run.index)
            while planned < size {
                let length = min(maximumBytes, size - planned)
                if !run.finished && length < minimumBytes { break }
                let part = Part(run: run.index, offset: planned, size: length)
                parts.append(part)
                added.append(part)
                planned += length
            }
        }
        return added
    }

    /// 区切りを切り出したときの SHA-256 を覚える。
    public mutating func recordDigest(run: Int, offset: Int, sha256: String) {
        guard let position = parts.firstIndex(where: { $0.run == run && $0.offset == offset }) else { return }
        parts[position].sha256 = sha256
    }

    public mutating func markUploaded(run: Int, offset: Int) {
        guard let position = parts.firstIndex(where: { $0.run == run && $0.offset == offset }) else { return }
        parts[position].uploaded = true
    }

    /// 閉じた走のファイルと、切り出したときのバイト列を比べ、違う区切りを上げ直しにする（上げ直す区切りを返す）。
    /// currentDigest は、閉じたファイルの同じ範囲の SHA-256。
    @discardableResult
    public mutating func invalidateChangedParts(run: Int, currentDigest: (Part) throws -> String) rethrows -> [Part] {
        var changed: [Part] = []
        for position in parts.indices where parts[position].run == run {
            guard let recorded = parts[position].sha256 else { continue }
            if try currentDigest(parts[position]) != recorded {
                parts[position].uploaded = false
                parts[position].sha256 = nil
                changed.append(parts[position])
            }
        }
        return changed
    }

    /// サーバーが「届いていない区切りがある」と答えたとき、その走の区切りをすべて上げ直しにする。
    public mutating func resendRun(_ run: Int) {
        for position in parts.indices where parts[position].run == run {
            parts[position].uploaded = false
            parts[position].sha256 = nil
        }
    }

    // MARK: サーバー

    /// サーバーに録音を作る要求（client_id で二重に作らない。文字起こしと要約まで頼む）。
    public var recordingRequest: MinutesCloudRecordingRequest {
        MinutesCloudRecordingRequest(clientId: clientId, source: source, title: title, startedAt: JSONCoding.iso8601Local(startedAt), timeZone: timeZone,
                                     language: language, contentType: Self.contentType, summarize: true, diarize: true)
    }

    /// 何も録れていない（止めたのに区切りがない）。サーバーに送らずに消す。
    public func isEmpty(fileSizes: [Int: Int]) -> Bool {
        stopped && runs.allSatisfy(\.finished) && runs.allSatisfy { (fileSizes[$0.index] ?? 0) == 0 }
    }

    /// complete を送れるか: 止めた・走がすべて閉じた・区切りがファイルの終わりまで決まって上がった・サーバーの ID がある。
    public func readyToComplete(fileSizes: [Int: Int]) -> Bool {
        guard stopped, !completed, serverId != nil, !runs.isEmpty, runs.allSatisfy(\.finished), parts.allSatisfy(\.uploaded) else { return false }
        guard runs.contains(where: { plannedBytes(run: $0.index) > 0 }) else { return false }
        return runs.allSatisfy { plannedBytes(run: $0.index) == (fileSizes[$0.index] ?? 0) }
    }

    /// complete に添える、走ごとのバイト数。
    public var runBytes: [MinutesCloudRunBytes] {
        runs.sorted { $0.index < $1.index }.map { MinutesCloudRunBytes(run: $0.index, bytes: plannedBytes(run: $0.index)) }
    }

    // MARK: ファイル

    public static func load(from directory: URL) throws -> MinutesCloudUpload {
        try JSONCoding.decoder().decode(MinutesCloudUpload.self, from: Data(contentsOf: directory.appending(path: fileName)))
    }

    public func save(to directory: URL) throws {
        try JSONCoding.encoder().encode(self).write(to: directory.appending(path: Self.fileName), options: .atomic)
    }

    /// 走のファイルから区切りのバイト列を読む。
    public static func readPart(_ part: Part, from runFile: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: runFile)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(part.offset))
        let data = try handle.read(upToCount: part.size) ?? Data()
        guard data.count == part.size else {
            throw MinutesCloudError.invalidResponse("録音のファイルが区切りより短い（\(runFile.lastPathComponent) \(part.offset)+\(part.size)、\(data.count) バイト）")
        }
        return data
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// ADTS（AAC のフレームの並び。先頭が 0xFFF の同期語）か。区切ってつなげられるのは ADTS だけ。
    public static func isADTS(_ header: Data) -> Bool {
        guard header.count >= 2 else { return false }
        let first = header[header.startIndex]
        let second = header[header.index(after: header.startIndex)]
        return first == 0xFF && (second & 0xF0) == 0xF0
    }
}
