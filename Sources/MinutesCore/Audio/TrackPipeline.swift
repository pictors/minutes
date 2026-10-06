import AVFoundation
import Foundation

/// 1 トラック分の統計（ログ / recording.json 用）。
public struct TrackStatsSnapshot: Sendable, Codable, Equatable {
    public var failure: CaptureFailure?
    public var archiveWrittenFrames: Int?
    public var sttWrittenFrames: Int?
    /// ホスト時計との比較で測定した入力レート。旧 manifest では nil。
    public var observedSampleRate: Double?
    public var liveStreamFailure: String?
    public var name: String
    public var sourceSampleRate: Double
    public var sourceChannels: Int
    public var archiveSampleRate: Double
    /// ソースから受け取った実フレーム数（ソースレート）。
    public var receivedFrames: Int
    public var receivedSeconds: Double
    /// 無音補完を含む、タイムライン上に書き出した秒数。
    public var writtenSeconds: Double
    /// 録音開始（t0）から最初のチャンクまでの遅れ（秒）。無音で補完済み。
    public var firstChunkOffsetSeconds: Double?
    public var gapCount: Int
    public var gapSeconds: Double
    /// 途切れたまま録音が終わったとき、停止時に末尾を無音で埋めた秒数（SPEC §4.3）。gapSeconds にも含む。
    public var tailPaddingSeconds: Double?
    public var overlapCount: Int
    public var overlapSeconds: Double
    public var formatChanges: Int
    /// 直近チャンクの RMS（dBFS）。
    public var lastRmsDb: Float
    /// 前回スナップショット以降の最大 RMS。
    public var intervalPeakRmsDb: Float
    /// RMS が -50 dBFS を超えた秒数（音があるかの確認用）。
    public var activeSeconds: Double
    /// 最後のチャンク末尾のタイムライン時刻（ホスト時刻ベース）。
    public var lastChunkTimelineEnd: Double?
    /// writtenSeconds − ホスト時刻ベースの経過。正 = デバイスクロックがホストより速い。
    public var driftSeconds: Double? {
        guard let lastChunkTimelineEnd else { return nil }
        return writtenSeconds - lastChunkTimelineEnd
    }
}

/// 生チャンク → タイムライン整合（先頭オフセット・欠落補完）→ mono → AAC（アーカイブ）+ 16 kHz WAV（STT）+ 16 kHz ストリーム。
/// 1 本のシリアルキューで処理する。
public final class TrackPipeline: @unchecked Sendable {
    public let name: String
    public let chunks: AsyncStream<AudioChunk>

    private let continuation: AsyncStream<AudioChunk>.Continuation
    private let queue: DispatchQueue
    private let timelineStartSeconds: Double
    private let archiveURL: URL?
    private let sttURL: URL?
    private let aacBitrate: Int
    private let activeThresholdDB: Float = -50

    private var started = false
    private var archiveFile: (any TrackFileWriting)?
    private var sttFile: (any TrackFileWriting)?
    private var archiveResampler: Resampler?
    private let sttResampler: Resampler
    private var stats: TrackStatsSnapshot
    private var lastRate: Double = 0
    private var lastChannels = 0
    private var clockMonitor = AudioClockMonitor()
    private var expectedSampleTime: Double = .nan
    private var written16kFrames = 0
    private var finished = false
    private var streamingLive: Bool
    private let onLiveFailure: (@Sendable (String) -> Void)?
    private let onFailure: (@Sendable (CaptureFailure) -> Void)?
    private let writerFactory: @Sendable (URL, [String: Any]) throws -> any TrackFileWriting

    public init(name: String, timelineStartHostTime: UInt64, archiveURL: URL?, sttURL: URL?, aacBitrate: Int = 64_000, streamLiveAudio: Bool = true, liveBufferLimit: Int = 256, onLiveFailure: (@Sendable (String) -> Void)? = nil, onFailure: (@Sendable (CaptureFailure) -> Void)? = nil, writerFactory: @escaping @Sendable (URL, [String: Any]) throws -> any TrackFileWriting = { try TrackFileWriter(url: $0, settings: $1) }) {
        self.streamingLive = streamLiveAudio
        self.onLiveFailure = onLiveFailure
        self.onFailure = onFailure
        self.writerFactory = writerFactory
        self.name = name
        self.timelineStartSeconds = HostClock.seconds(fromHostTime: timelineStartHostTime)
        self.archiveURL = archiveURL
        self.sttURL = sttURL
        self.aacBitrate = aacBitrate
        self.queue = DispatchQueue(label: "jp.pictors.minutes.track.\(name)", qos: .userInitiated)
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingOldest(max(1, liveBufferLimit)))
        self.chunks = stream
        self.continuation = continuation
        if !streamLiveAudio { continuation.finish() }
        guard let resampler = Resampler(outputSampleRate: AudioFileTools.sttSampleRate) else {
            fatalError("16 kHz mono format unavailable")
        }
        self.sttResampler = resampler
        self.stats = TrackStatsSnapshot(
            name: name, sourceSampleRate: 0, sourceChannels: 0, archiveSampleRate: 0,
            receivedFrames: 0, receivedSeconds: 0, writtenSeconds: 0, firstChunkOffsetSeconds: nil,
            gapCount: 0, gapSeconds: 0, overlapCount: 0, overlapSeconds: 0, formatChanges: 0,
            lastRmsDb: -120, intervalPeakRmsDb: -120, activeSeconds: 0, lastChunkTimelineEnd: nil
        )
    }

    /// オーディオスレッドから呼ぶ。コピー済みチャンクをキューに渡すだけ。
    public func enqueue(_ chunk: PCMChunk) {
        queue.async { [self] in self.process(chunk) }
    }

    /// 統計を読む。`resetIntervalPeak` で区間ピークをリセットする。
    public func snapshot(resetIntervalPeak: Bool = false) -> TrackStatsSnapshot {
        queue.sync {
            let current = stats
            if resetIntervalPeak { stats.intervalPeakRmsDb = -120 }
            return current
        }
    }

    /// 最後の音声が録音の終了よりこれ以上前なら、途切れたまま終わったとみなして末尾を埋める。
    /// 正常なトラックの停止処理の遅れ（数百 ms）は埋めない。
    static let tailPaddingThreshold: Double = 1
    /// 一度も音声が届かなかったトラックを無音で作るときのレート。
    static let silentTrackSampleRate: Double = 48_000

    /// ファイルを閉じてストリームを終了する。
    /// `padTo` を渡すと、途切れたまま終わったトラックの末尾を録音の終了（タイムラインの秒）まで無音で埋める（SPEC §4.3）。
    public func finish(padTo timelineEnd: Double? = nil) -> TrackStatsSnapshot {
        queue.sync {
            guard !finished else { return stats }
            finished = true
            if stats.failure == nil {
                if let timelineEnd { padTail(to: timelineEnd) }
                if let tail = sttResampler.flush() { writeSTT(tail, yield: true) }
                if stats.failure == nil, let archiveResampler, let tail = archiveResampler.flush() { writeArchive(tail) }
            }
            archiveFile?.close()
            sttFile?.close()
            archiveFile = nil
            sttFile = nil
            continuation.finish()
            return stats
        }
    }

    // MARK: - Processing (queue)

    private func process(_ inputChunk: PCMChunk) {
        guard !finished, stats.failure == nil else { return }
        var chunk = inputChunk
        let rate = chunk.sampleRate
        guard rate.isFinite, rate > 0, chunk.frameCount > 0 else { return }
        if let problem = clockMonitor.observe(chunk) {
            stats.observedSampleRate = clockMonitor.observedSampleRate
            fail("音声クロックの検証", error: AudioCaptureError.invalidState(problem))
            return
        }
        stats.observedSampleRate = clockMonitor.observedSampleRate
        stats.receivedFrames += inputChunk.frameCount
        stats.receivedSeconds += Double(inputChunk.frameCount) / rate
        let hostSeconds: Double? = chunk.hostTime != 0 ? HostClock.seconds(fromHostTime: chunk.hostTime) - timelineStartSeconds : nil

        if !started {
            started = true
            lastRate = rate
            lastChannels = chunk.channelCount
            stats.sourceSampleRate = rate
            stats.sourceChannels = chunk.channelCount
            stats.archiveSampleRate = rate
            openFiles(rate: rate)
            guard stats.failure == nil else { return }
            let offset = hostSeconds ?? 0
            stats.firstChunkOffsetSeconds = offset
            if offset > 0.001 {
                writeSilence(seconds: offset, rate: rate)
            } else if offset < -0.001 {
                let drop = min(chunk.frameCount, Int(-offset * rate))
                chunk = trimmed(chunk, droppingFirst: drop)
            }
        } else {
            let formatChanged = rate != lastRate || chunk.channelCount != lastChannels
            if formatChanged {
                // 旧 converter の末尾を保存してから新形式へ。元レートへの復帰時も作り直す。
                if let tail = sttResampler.flush() { writeSTT(tail, yield: true) }
                if let archiveResampler, let tail = archiveResampler.flush() { writeArchive(tail) }
                sttResampler.reset()
                archiveResampler?.reset()
                stats.formatChanges += 1
                stats.sourceSampleRate = rate
                stats.sourceChannels = chunk.channelCount
            }
            let continuous = !formatChanged && chunk.sampleTime.isFinite && expectedSampleTime.isFinite
            if continuous {
                let delta = chunk.sampleTime - expectedSampleTime
                let sane = abs(delta) < rate * 30
                if delta > 0.5, sane {
                    stats.gapCount += 1
                    stats.gapSeconds += delta / rate
                    writeSilence(seconds: delta / rate, rate: rate)
                } else if delta < -0.5, sane {
                    stats.overlapCount += 1
                    stats.overlapSeconds += -delta / rate
                    chunk = trimmed(chunk, droppingFirst: min(chunk.frameCount, Int(-delta)))
                } else if !sane {
                    realignByHostTime(hostSeconds, rate: rate, chunk: &chunk)
                }
            } else {
                realignByHostTime(hostSeconds, rate: rate, chunk: &chunk)
            }
            lastRate = rate
            lastChannels = chunk.channelCount
        }

        guard stats.failure == nil else { return }
        guard chunk.frameCount > 0 else {
            expectedSampleTime = inputChunk.sampleTime + Double(inputChunk.frameCount)
            return
        }

        let mono = chunk.monoSamples()
        let level = AudioLevel.rmsDB(mono)
        stats.lastRmsDb = level
        stats.intervalPeakRmsDb = max(stats.intervalPeakRmsDb, level)
        if level > activeThresholdDB { stats.activeSeconds += Double(mono.count) / rate }
        write(mono: mono, rate: rate)

        expectedSampleTime = inputChunk.sampleTime.isFinite ? inputChunk.sampleTime + Double(inputChunk.frameCount) : .nan
        if let hostSeconds { stats.lastChunkTimelineEnd = hostSeconds + Double(inputChunk.frameCount) / rate }
    }

    /// サンプル時刻の連続性が失われたとき、ホスト時刻で書き出し位置を合わせ直す。
    private func realignByHostTime(_ hostSeconds: Double?, rate: Double, chunk: inout PCMChunk) {
        guard let hostSeconds else { return }
        let diff = hostSeconds - stats.writtenSeconds
        if diff > 0.02 {
            stats.gapCount += 1
            stats.gapSeconds += diff
            writeSilence(seconds: diff, rate: rate)
        } else if diff < -0.02 {
            stats.overlapCount += 1
            stats.overlapSeconds += -diff
            chunk = trimmed(chunk, droppingFirst: min(chunk.frameCount, Int(-diff * rate)))
        }
    }

    private func trimmed(_ chunk: PCMChunk, droppingFirst count: Int) -> PCMChunk {
        guard count > 0 else { return chunk }
        var copy = chunk
        copy.channels = chunk.channels.map { Array($0.dropFirst(count)) }
        if chunk.sampleTime.isFinite { copy.sampleTime = chunk.sampleTime + Double(count) }
        if chunk.hostTime != 0 { copy.hostTime = chunk.hostTime + HostClock.hostTime(fromSeconds: Double(count) / chunk.sampleRate) }
        return copy
    }

    private func openFiles(rate: Double) {
        if let archiveURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: aacBitrate,
            ]
            do {
                try? FileManager.default.removeItem(at: archiveURL)
                archiveFile = try writerFactory(archiveURL, settings)
                archiveResampler = Resampler(outputSampleRate: rate)
            } catch {
                fail("AAC ファイル作成", error: error)
                return
            }
        }
        if let sttURL {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: AudioFileTools.sttSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            do {
                try? FileManager.default.removeItem(at: sttURL)
                sttFile = try writerFactory(sttURL, settings)
            } catch {
                fail("WAV ファイル作成", error: error)
            }
        }
    }

    /// 最後の音声から録音の終了までを無音で埋める。一度も音声が届かなかったトラックは、全体を無音のファイルにする。
    /// 停止時の穴埋めはライブ字幕に流さない（数分の無音で字幕のバッファを溢れさせない）。
    private func padTail(to timelineEnd: Double) {
        guard timelineEnd - (stats.lastChunkTimelineEnd ?? 0) > Self.tailPaddingThreshold else { return }
        let missing = timelineEnd - stats.writtenSeconds
        guard missing > 0 else { return }
        if !started {
            started = true
            lastRate = Self.silentTrackSampleRate
            stats.archiveSampleRate = lastRate
            openFiles(rate: lastRate)
            guard stats.failure == nil else { return }
        }
        stats.gapCount += 1
        stats.gapSeconds += missing
        stats.tailPaddingSeconds = missing
        writeSilence(seconds: missing, rate: lastRate, yieldLive: false)
    }

    private func writeSilence(seconds: Double, rate: Double, yieldLive: Bool = true) {
        var remaining = Int(seconds * rate)
        while remaining > 0, stats.failure == nil {
            let count = min(remaining, Int(rate))
            write(mono: [Float](repeating: 0, count: count), rate: rate, yieldLive: yieldLive)
            remaining -= count
        }
    }

    private func fail(_ operation: String, error: any Error) {
        guard stats.failure == nil else { return }
        let failure = CaptureFailure(track: name, operation: operation, message: error.localizedDescription)
        stats.failure = failure
        continuation.finish()
        onFailure?(failure)
    }

    private func write(mono: [Float], rate: Double, yieldLive: Bool = true) {
        guard stats.failure == nil, let buffer = PCMChunk.monoBuffer(samples: mono, sampleRate: rate) else { return }
        do {
            if archiveFile != nil, let archiveResampler {
                writeArchive(try archiveResampler.convert(buffer))
            }
            guard stats.failure == nil else { return }
            writeSTT(try sttResampler.convert(buffer), yield: yieldLive)
            if stats.failure == nil { stats.writtenSeconds += Double(mono.count) / rate }
        } catch { fail("音声変換", error: error) }
    }

    private func writeArchive(_ buffer: AVAudioPCMBuffer) {
        guard stats.failure == nil, buffer.frameLength > 0, let archiveFile else { return }
        do {
            try archiveFile.write(from: buffer)
            stats.archiveWrittenFrames = (stats.archiveWrittenFrames ?? 0) + Int(buffer.frameLength)
        } catch { fail("AAC 書き込み", error: error) }
    }

    private func writeSTT(_ buffer: AVAudioPCMBuffer, yield: Bool) {
        guard stats.failure == nil, buffer.frameLength > 0 else { return }
        if let sttFile {
            do {
                try sttFile.write(from: buffer)
                stats.sttWrittenFrames = (stats.sttWrittenFrames ?? 0) + Int(buffer.frameLength)
            } catch { fail("WAV 書き込み", error: error); return }
        }
        if yield, streamingLive, let data = buffer.floatChannelData {
            // 1 要素は最大 100 ms。無音補完の大きな入力でもバッファ量の上限を守る。
            for offset in stride(from: 0, to: Int(buffer.frameLength), by: 1600) {
                let count = min(1600, Int(buffer.frameLength) - offset)
                let samples = Array(UnsafeBufferPointer(start: data[0] + offset, count: count))
                let startTime = Double(written16kFrames + offset) / AudioFileTools.sttSampleRate
                switch continuation.yield(AudioChunk(samples: samples, sampleRate: AudioFileTools.sttSampleRate, startTime: startTime)) {
                case .enqueued: continue
                case .dropped:
                    let message = "\(name) のライブ字幕が追いつかないため字幕を終了しました。録音処理は継続します。"
                    stats.liveStreamFailure = message
                    onLiveFailure?(message)
                    streamingLive = false
                    continuation.finish()
                case .terminated: streamingLive = false
                @unknown default: streamingLive = false; continuation.finish()
                }
                break
            }
        }
        written16kFrames += Int(buffer.frameLength)
    }
}
