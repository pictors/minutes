import Foundation

/// 話者割当時に、そのクラスタから最もクリーンな 5〜8 秒を切り出して people.voice_samples に保存する（SPEC §5.4）。
public enum VoiceSampleExtractor {
    public static let minimumSeconds = 5.0
    public static let maximumSeconds = 8.0

    /// クラスタのセグメントのうち、5 秒以上で RMS が最も高い区間を最大 8 秒で切り出す。
    /// 候補区間だけを読むので、60 分の録音でもファイル全体をメモリに載せない。候補は長い順に最大 `maxCandidates` 件。
    public static func extract(clusterLabel: String, segments: [SegmentRecord], audioURL: URL, outputURL: URL, meetingId: String, maxCandidates: Int = 24) throws -> VoiceSample? {
        let candidates = segments
            .filter { $0.clusterLabel == clusterLabel && ($0.tEnd - $0.tStart) >= minimumSeconds }
            .sorted { ($0.tEnd - $0.tStart) > ($1.tEnd - $1.tStart) }
            .prefix(maxCandidates)
        guard !candidates.isEmpty else { return nil }
        let rate = AudioFileTools.sttSampleRate
        var best: (samples: [Float], level: Float)?
        for segment in candidates {
            let end = min(segment.tEnd, segment.tStart + maximumSeconds)
            let samples = try AudioFileTools.loadMono16k(audioURL, from: segment.tStart, to: end)
            guard !samples.isEmpty else { continue }
            let level = AudioLevel.rmsDB(samples)
            if best == nil || level > best!.level { best = (samples, level) }
        }
        guard let chosen = best?.samples else { return nil }
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AudioFileTools.writeWAV(samples: chosen, sampleRate: rate, to: outputURL)
        return VoiceSample(path: outputURL.path, duration: Double(chosen.count) / rate, meetingId: meetingId)
    }
}
