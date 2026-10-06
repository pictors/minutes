import AVFoundation
import Foundation

/// 背景の声（相手のマイクが拾った周りの会話）を見分け、話者単位で除外する（SPEC §5.4）。
///
/// Meet は参加者の声の大きさをそろえるので、本人の声は話者が違ってもほぼ同じ大きさで届き、周りの会話だけが小さく残る
/// （実会議 7 本: 参加者はいちばん長く話した人との差が 0〜−5 dB、背景の声は −15 dB）。発話 1 件ずつの音量は範囲が重なるので、
/// 話者分離のクラスタ単位で比べる。音声は加工しない。除外は本文の表示・要約・書き出し・検索から発話を外すだけで、DB には残る。
public enum BackgroundVoices {
    /// いちばん長く話した相手側の話者との差がこれ以下なら、背景の声の候補にする（dB）。
    public static let candidateThresholdDB = -10.0
    /// 話者の音量に使う発話の最短の長さ（秒）。短い相づちや、単語の途中で切れた断片は音量が安定しない。
    static let minimumSegmentSeconds = 0.8
    /// RMS を取る窓（秒）。
    static let frameSeconds = 0.02

    // MARK: - 除外

    /// 除外した話者の発話か。発話単位で話者を変えていれば、変えた先の話者で決める。
    public static func isExcluded(_ segment: SegmentRecord, speakers: [SpeakerRecord]) -> Bool {
        segment.speaker(in: speakers)?.excluded ?? false
    }

    /// 除外した話者の発話を除く。
    public static func removingExcluded(_ segments: [SegmentRecord], speakers: [SpeakerRecord]) -> [SegmentRecord] {
        guard speakers.contains(where: \.excluded) else { return segments }
        return segments.filter { !isExcluded($0, speakers: speakers) }
    }

    /// 相手側の話者分離のクラスタか（自分の声と、発話単位の割当用の行を除く）。音量を測り、除外できるのはこの話者だけ。
    public static func isRemoteCluster(_ label: String?) -> Bool {
        guard let label else { return false }
        return label != TrackMerger.micSpeakerLabel && !label.hasPrefix("manual_")
    }

    // MARK: - 候補

    /// 相手側の話者ごとの音量の差（dB）。除外していない話者のうち、いちばん長く話したクラスタを 0 とする。音量を測っていない話者は含めない。
    /// キーは speakers.id。発言時間はクラスタ（発話単位の変更の前）で数える。音量はクラスタの声の大きさなので、基準もクラスタでそろえる。
    /// 除外した話者を基準にしないのは、周りの会話がいちばん長かった会議でも、除外したあとは参加者を基準に比べ直せるようにするため。
    public static func relativeLevels(speakers: [SpeakerRecord], segments: [SegmentRecord]) -> [String: Double] {
        var seconds: [String: Double] = [:]
        for segment in segments {
            guard let label = segment.clusterLabel, isRemoteCluster(label) else { continue }
            seconds[label, default: 0] += max(0, segment.tEnd - segment.tStart)
        }
        let measured = speakers.filter { isRemoteCluster($0.clusterLabel) && $0.levelDb != nil && seconds[$0.clusterLabel] != nil }
        // 発言時間が同じなら、先に並ぶ話者を基準にする
        guard let reference = measured.filter({ !$0.excluded }).max(by: { seconds[$0.clusterLabel, default: 0] < seconds[$1.clusterLabel, default: 0] }),
              let base = reference.levelDb else { return [:] }
        var result: [String: Double] = [:]
        for speaker in measured {
            if let level = speaker.levelDb { result[speaker.id] = level - base }
        }
        return result
    }

    /// 背景の声の候補（speakers.id → いちばん長く話した相手側の話者との差 dB）。除外済みの話者と、名前を割り当てた話者は含めない。
    public static func candidates(speakers: [SpeakerRecord], segments: [SegmentRecord]) -> [String: Double] {
        let byId = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        return relativeLevels(speakers: speakers, segments: segments).filter { id, delta in
            guard delta <= candidateThresholdDB, let speaker = byId[id] else { return false }
            return !speaker.excluded && speaker.displayName == nil
        }
    }

    // MARK: - 音量の測定

    /// 会議の相手側の話者の音量を測って保存する。後処理（音声を消す前）と、それより前に処理した会議を開いたときに呼ぶ。
    /// 相手側の音声がなければ何もしない。音量を保存した話者の数を返す。
    @discardableResult
    public static func measureAndStore(store: Store, meetingId: String, audioDirectory: URL) throws -> Int {
        let files = [RecordingSession.systemSTTName, RecordingSession.systemArchiveName].map { audioDirectory.appendingPathComponent($0) }
        guard let audioURL = files.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return 0 }
        let levels = try measureLevels(segments: try store.segments(meetingId: meetingId, source: .final), audioURL: audioURL)
        try store.setSpeakerLevels(meetingId: meetingId, levels: levels)
        return levels.count
    }

    /// 相手側のクラスタごとの音量（dBFS）。発話区間を 20 ms ごとの RMS にして区間ごとに 90 パーセンタイル（話している部分の大きさ。
    /// 間の無音に引きずられない）を取り、0.8 秒以上の発話の中央値（なければ全発話の中央値）を話者の音量とする。キーはクラスタラベル。
    public static func measureLevels(segments: [SegmentRecord], audioURL: URL) throws -> [String: Double] {
        let remote = segments.filter { isRemoteCluster($0.clusterLabel) }
        guard !remote.isEmpty else { return [:] }
        let frames = try frameLevels(of: audioURL)
        var long: [String: [Double]] = [:]
        var all: [String: [Double]] = [:]
        for segment in remote {
            guard let label = segment.clusterLabel, let level = segmentLevel(frames, start: segment.tStart, end: segment.tEnd) else { continue }
            all[label, default: []].append(level)
            if segment.tEnd - segment.tStart >= minimumSegmentSeconds { long[label, default: []].append(level) }
        }
        var result: [String: Double] = [:]
        for (label, levels) in all {
            result[label] = percentile(long[label] ?? levels, 0.5)
        }
        return result
    }

    /// 音声全体を 20 ms ごとの RMS（dBFS、無音は −120）にする。先頭から一度だけ読み、サンプルは保持しない（60 分でも数 MB）。
    static func frameLevels(of url: URL) throws -> [Double] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw TranscriptionError.unsupportedAudio("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let frameLength = max(1, Int((format.sampleRate * frameSeconds).rounded()))
        guard channels > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw AudioCaptureError.conversionFailed("音量の測定用のバッファを作れません")
        }
        var levels: [Double] = []
        levels.reserveCapacity(Int(file.length) / frameLength + 1)
        var sumOfSquares = 0.0
        var count = 0
        let scale = 1 / Float(channels)
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
            let length = Int(buffer.frameLength)
            guard length > 0, let data = buffer.floatChannelData else { break }
            for index in 0..<length {
                var sample: Float = 0
                for channel in 0..<channels { sample += data[channel][index] }
                sample *= scale
                sumOfSquares += Double(sample * sample)
                count += 1
                if count == frameLength {
                    levels.append(decibels(meanSquare: sumOfSquares / Double(count)))
                    sumOfSquares = 0
                    count = 0
                }
            }
        }
        if count > 0 { levels.append(decibels(meanSquare: sumOfSquares / Double(count))) }
        return levels
    }

    static func decibels(meanSquare: Double) -> Double {
        let rms = meanSquare.squareRoot()
        return rms > 1e-6 ? 20 * log10(rms) : -120
    }

    /// 発話区間の 90 パーセンタイル（dBFS）。区間が音声より後ろなら nil。
    static func segmentLevel(_ frames: [Double], start: Double, end: Double) -> Double? {
        let first = max(0, Int(start / frameSeconds))
        guard first < frames.count else { return nil }
        let last = min(frames.count, max(Int(end / frameSeconds), first + 1))
        return percentile(Array(frames[first..<last]), 0.9)
    }

    /// 線形補間のパーセンタイル（`fraction` は 0〜1）。空なら nil。
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
