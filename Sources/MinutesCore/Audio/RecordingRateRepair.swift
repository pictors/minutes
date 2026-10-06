import Foundation

/// 既知の一定レート誤認だけを、原本を変更せず別フォルダへ回復する。
/// 自動推定で原音を修正しない。形式変更・欠落のある録音は個別調査が必要。
public enum RecordingRateRepair {
    public static func prepareCopy(source: URL, destination: URL, track: String, actualSampleRate: Double) throws {
        let fm = FileManager.default
        guard ["system", "mic"].contains(track), actualSampleRate.isFinite, actualSampleRate >= 8_000, actualSampleRate <= 192_000 else {
            throw AudioCaptureError.invalidState("system / mic と有効な実入力レートを指定してください")
        }
        guard !fm.fileExists(atPath: destination.path) else {
            throw AudioCaptureError.invalidState("出力先が既に存在します。新しいフォルダを指定してください")
        }
        var manifest = try RecordingManifest.read(from: source)
        guard var stats = manifest.tracks[track], stats.failure == nil,
              stats.formatChanges == 0, stats.gapCount == 0, stats.overlapCount == 0,
              let offset = stats.firstChunkOffsetSeconds, offset >= 0,
              let end = stats.lastChunkTimelineEnd, stats.archiveSampleRate > 0,
              stats.sourceSampleRate == stats.archiveSampleRate else {
            throw AudioCaptureError.invalidState("一定レートの取り違えと確認できる録音統計が必要です")
        }
        let factor = stats.archiveSampleRate / actualSampleRate
        guard abs(factor - 1) > 0.01,
              abs(offset + stats.receivedSeconds * factor - end) <= max(0.1, end * 0.001) else {
            throw AudioCaptureError.invalidState("指定レートでは録音時計と一致しません。原音は変更していません")
        }
        let archiveName = track == "system" ? RecordingSession.systemArchiveName : RecordingSession.micArchiveName
        let sttName = track == "system" ? RecordingSession.systemSTTName : RecordingSession.micSTTName
        let originalSamples = try AudioFileTools.load(source.appendingPathComponent(archiveName), targetSampleRate: stats.archiveSampleRate)
        let originalPadding = Int((offset * stats.archiveSampleRate).rounded())
        guard originalPadding < originalSamples.count else { throw AudioCaptureError.invalidState("音声サンプルがありません") }
        var repaired = [Float](repeating: 0, count: Int((offset * actualSampleRate).rounded()))
        repaired.append(contentsOf: originalSamples.dropFirst(originalPadding))
        let repairedDuration = Double(repaired.count) / actualSampleRate
        guard abs(repairedDuration - end) < max(0.1, end * 0.001) else {
            throw AudioCaptureError.invalidState("補正結果と録音時計が一致しません")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var complete = false
        defer { if !complete { try? fm.removeItem(at: destination) } }
        // 旧統計と原本の所在を残す。原本・既存 DB の本文は一切更新しない。
        try fm.copyItem(at: source.appendingPathComponent(RecordingManifest.fileName), to: destination.appendingPathComponent("recovery-source-recording.json"))
        for other in ["system", "mic"] where other != track {
            for name in ["\(other).m4a", "\(other)_16k.wav"] where fm.fileExists(atPath: source.appendingPathComponent(name).path) {
                try fm.copyItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        }
        let decoded = destination.appendingPathComponent("repaired-source.wav")
        try AudioFileTools.writeWAV(samples: repaired, sampleRate: actualSampleRate, to: decoded)
        let sttSamples = try AudioFileTools.loadMono16k(decoded)
        try AudioFileTools.writeWAV(samples: sttSamples, sampleRate: AudioFileTools.sttSampleRate, to: destination.appendingPathComponent(sttName))
        try AudioFileTools.writeAAC(samples: repaired, sampleRate: actualSampleRate, to: destination.appendingPathComponent(archiveName), bitrate: 64_000)
        try fm.removeItem(at: decoded)
        stats.sourceSampleRate = actualSampleRate
        stats.archiveSampleRate = actualSampleRate
        stats.observedSampleRate = actualSampleRate
        stats.receivedSeconds = Double(stats.receivedFrames) / actualSampleRate
        stats.writtenSeconds = repairedDuration
        stats.archiveWrittenFrames = repaired.count
        stats.sttWrittenFrames = sttSamples.count
        stats.activeSeconds *= factor
        manifest.tracks[track] = stats
        manifest.id = UUID().uuidString.lowercased()
        manifest.title = (manifest.title ?? "会議") + "（音声補正版）"
        manifest.events.append("rate repair: \(track), \(factor)x duration, actual \(actualSampleRate) Hz; original: \(source.path)")
        try RecordingAudioValidation.validate(stats: stats, fileDuration: Double(sttSamples.count) / AudioFileTools.sttSampleRate, recordingDuration: manifest.durationSeconds)
        try manifest.write(to: destination)
        try JSONCoding.encoder().encode(manifest.tracks.keys.sorted()).write(to: destination.appendingPathComponent("expected-tracks.json"))
        complete = true
    }
}
