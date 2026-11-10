import Foundation

/// 録音のフォルダに残す、会議が始まったかの印（SPEC §6.4）。アプリが落ちたあとの起動で、録音準備だけで終わった録音
/// （会議ではない。送らずに消す）と、会議の録音（録れた音声で議事録を作る）を見分ける。
/// DB の列にしないのは、古い版と同じ DB を開けるようにするため（列を足すとスキーマの版が上がる）。印のない録音
/// （印を書く前の版で録った・印を書く前に落ちた）は、これまでどおり中断として残し、利用者が再実行を選ぶ。
public enum RecordingPhase: String, Codable, Sendable {
    /// 録音準備（予定の開始の前から、会議の音声を待っている）
    case armed
    /// 会議の録音（音声の検知・開始のボタン・確認の承認で始まった）
    case meeting

    public static let fileName = "recording-phase.json"

    private struct File: Codable {
        var phase: RecordingPhase
    }

    /// 印がない・読めないときは nil。
    public static func read(in directory: URL) -> RecordingPhase? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONCoding.decoder().decode(File.self, from: data).phase
    }

    public func write(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONCoding.encoder().encode(File(phase: self)).write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
