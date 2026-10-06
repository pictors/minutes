import Foundation
import MinutesCore

/// 音声ファイルの一部を 16 kHz mono WAV に切り出す（実会議の録音から評価用の区間を作る、known-speaker の参照音声を作る）。
enum CutCommand {
    static let spec = ArgumentSpec(options: ["start", "end", "duration"], flags: [])

    static func run(_ arguments: [String]) throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        guard parsed.positionals.count >= 2 else {
            throw ArgumentError.missingPositional(parsed.positionals.isEmpty ? "input" : "output.wav")
        }
        let input = URL(fileURLWithPath: parsed.positionals[0])
        let output = URL(fileURLWithPath: parsed.positionals[1])
        let start = try parsed.value("start").map(parseTime) ?? 0
        var end: Double?
        if let endRaw = parsed.value("end") { end = try parseTime(endRaw) }
        if let durationRaw = parsed.value("duration") { end = start + (try parseTime(durationRaw)) }

        Console.info("読み込み中: \(input.lastPathComponent)")
        let samples = try AudioFileTools.loadMono16k(input)
        let rate = AudioFileTools.sttSampleRate
        let total = Double(samples.count) / rate
        let stop = min(end ?? total, total)
        guard start < stop else {
            throw ArgumentError.invalidValue(option: "start", value: String(start), expected: "終了時刻 \(stop) 秒より前")
        }
        let range = Int(start * rate)..<Int(stop * rate)
        try AudioFileTools.writeWAV(samples: Array(samples[range]), sampleRate: rate, to: output)
        Console.out(String(format: "%@: %.1f–%.1f s (%.1f s) → %@ (%@)", input.lastPathComponent, start, stop, stop - start, output.path, Console.formatBytes((try? AudioFileTools.fileSize(output)) ?? 0)))
    }

    /// "90" / "1:30" / "0:01:30" / "1:30.5" を秒にする。
    static func parseTime(_ raw: String) throws -> Double {
        let parts = raw.split(separator: ":").map { String($0) }
        guard !parts.isEmpty, parts.count <= 3 else { throw ArgumentError.invalidValue(option: "time", value: raw, expected: "秒 または mm:ss / hh:mm:ss") }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { throw ArgumentError.invalidValue(option: "time", value: raw, expected: "秒 または mm:ss / hh:mm:ss") }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}
