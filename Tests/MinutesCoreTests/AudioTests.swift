import AVFoundation
import Foundation
import MinutesCore
import Testing

@Suite("音声ファイル / タイムライン")
struct AudioTests {
    func sine(seconds: Double, rate: Double, frequency: Double = 440, amplitude: Float = 0.5) -> [Float] {
        let count = Int(seconds * rate)
        return (0..<count).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    @Test("WAV ヘッダと往復読み込み（44.1k → 16k 変換）")
    func wavRoundTrip() throws {
        let rate = 44_100.0
        let samples = sine(seconds: 1.0, rate: rate)
        let data = AudioFileTools.wavData(samples: samples, sampleRate: rate)
        #expect(data.count == 44 + samples.count * 2)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        #expect(abs((try AudioFileTools.duration(of: url)) - 1.0) < 0.001)
        let loaded = try AudioFileTools.loadMono16k(url)
        #expect(abs(Double(loaded.count) / 16_000 - 1.0) < 0.01)
        #expect(AudioLevel.rmsDB(loaded) > -12 && AudioLevel.rmsDB(loaded) < -6)
    }

    @Test("無音位置で分割点を選ぶ")
    func quietSplit() {
        let rate = 16_000.0
        var samples = sine(seconds: 30, rate: rate)
        // 12.0〜12.5 秒を無音にする
        for index in Int(12.0 * rate)..<Int(12.5 * rate) { samples[index] = 0 }
        let points = AudioFileTools.quietSplitPoints(samples: samples, sampleRate: rate, targetChunkSeconds: 10, searchWindowSeconds: 5)
        #expect(points.count >= 1)
        let first = points[0]
        #expect(first > 12.0 && first < 12.5)
        #expect(AudioFileTools.quietSplitPoints(samples: samples, sampleRate: rate, targetChunkSeconds: 60).isEmpty)
    }

    @Test("AAC 書き出しと読み戻し")
    func aac() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-test-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioFileTools.writeAAC(samples: sine(seconds: 2, rate: 16_000), sampleRate: 16_000, to: url, bitrate: 32_000)
        let size = try AudioFileTools.fileSize(url)
        #expect(size > 2_000 && size < 40_000)
        let loaded = try AudioFileTools.loadMono16k(url)
        #expect(abs(Double(loaded.count) / 16_000 - 2.0) < 0.15)
    }

    @Test("TrackPipeline: 先頭オフセットと欠落を無音で補完し、タイムラインを保つ")
    func pipelineTimeline() throws {
        let rate = 48_000.0
        let t0 = HostClock.now()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = TrackPipeline(name: "test", timelineStartHostTime: t0, archiveURL: nil, sttURL: url)

        let frames = 4800 // 0.1 s
        let tone = sine(seconds: 0.1, rate: rate)
        var sampleTime = 1_000.0
        // 最初のチャンクは t0 + 0.5 s に届く
        var hostTime = t0 + HostClock.hostTime(fromSeconds: 0.5)
        for _ in 0..<5 {
            pipeline.enqueue(PCMChunk(channels: [tone, tone], sampleRate: rate, hostTime: hostTime, sampleTime: sampleTime))
            sampleTime += Double(frames)
            hostTime += HostClock.hostTime(fromSeconds: 0.1)
        }
        // 0.3 s の欠落
        sampleTime += 0.3 * rate
        hostTime += HostClock.hostTime(fromSeconds: 0.3)
        for _ in 0..<5 {
            pipeline.enqueue(PCMChunk(channels: [tone, tone], sampleRate: rate, hostTime: hostTime, sampleTime: sampleTime))
            sampleTime += Double(frames)
            hostTime += HostClock.hostTime(fromSeconds: 0.1)
        }
        let stats = pipeline.finish()
        #expect(stats.gapCount == 1)
        #expect(abs(stats.gapSeconds - 0.3) < 0.001)
        #expect(abs((stats.firstChunkOffsetSeconds ?? 0) - 0.5) < 0.002)
        #expect(abs(stats.receivedSeconds - 1.0) < 0.001)
        #expect(abs(stats.writtenSeconds - 1.8) < 0.001)
        #expect(stats.sourceChannels == 2)
        let drift = try #require(stats.driftSeconds)
        #expect(abs(drift) < 0.005)

        let duration = try AudioFileTools.duration(of: url)
        #expect(abs(duration - 1.8) < 0.02)
        let loaded = try AudioFileTools.loadMono16k(url)
        // 先頭 0.5 s は無音、0.5〜1.0 s は音あり、1.0〜1.3 s は無音
        #expect(AudioLevel.rmsDB(Array(loaded[0..<7_000])) < -80)
        #expect(AudioLevel.rmsDB(Array(loaded[9_000..<15_000])) > -12)
        #expect(AudioLevel.rmsDB(Array(loaded[16_400..<20_400])) < -80)
    }

    @Test("PCMChunk の mono 変換と AVAudioPCMBuffer からの取り込み")
    func chunk() throws {
        let chunk = PCMChunk(channels: [[1, 1, 1], [0, 0, 0]], sampleRate: 48_000, hostTime: 0, sampleTime: 0)
        #expect(chunk.monoSamples() == [0.5, 0.5, 0.5])
        #expect(chunk.frameCount == 3)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2))
        buffer.frameLength = 2
        buffer.floatChannelData![0][0] = 0.25
        buffer.floatChannelData![0][1] = 0.75
        buffer.floatChannelData![0][2] = -0.25
        buffer.floatChannelData![0][3] = -0.75
        let imported = try #require(PCMChunk(buffer: buffer, hostTime: 1, sampleTime: 2))
        #expect(imported.channels == [[0.25, -0.25], [0.75, -0.75]])
    }
}
