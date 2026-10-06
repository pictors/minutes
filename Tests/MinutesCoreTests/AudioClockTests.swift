import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import MinutesCore

@Suite("録音時計と音声形式")
struct AudioClockTests {
    @Test("実録音のプロセス ID を含む旧 manifest が往復できる")
    func processMetadata() throws {
        let json = Data(#"{"object_id":152,"pid":1234,"bundle_id":"com.example.browser.helper","parent_pid":123,"is_running_output":true,"is_running_input":false}"#.utf8)
        let process = try JSONCoding.decoder().decode(AudioProcessInfo.self, from: json)
        #expect(process.objectID == 152)
        #expect(process.bundleID == "com.example.browser.helper")
        #expect(process.parentPID == 123)
        var manifest = makeManifest(stats: brokenStats())
        manifest.tappedProcesses = [process]
        let decoded = try JSONCoding.decoder().decode(RecordingManifest.self, from: JSONCoding.encoder().encode(manifest))
        #expect(decoded.tappedProcesses == [process])
    }

    @Test("24 kHz を 48 kHz と誤認しても、連続 sampleTime と独立に異常を検知")
    func wrongRate() {
        let failures = Mutex<[CaptureFailure]>([])
        let t0 = HostClock.now()
        let pipeline = TrackPipeline(name: "system", timelineStartHostTime: t0, archiveURL: nil, sttURL: nil,
                                     onFailure: { f in failures.withLock { $0.append(f) } })
        for i in 0..<200 {
            pipeline.enqueue(PCMChunk(channels: [Array(repeating: 0.1, count: 480)], sampleRate: 48_000,
                                      hostTime: t0 + HostClock.hostTime(fromSeconds: Double(i) * 0.02), sampleTime: Double(i * 480)))
        }
        let stats = pipeline.finish()
        #expect(stats.failure?.operation == "音声クロックの検証")
        #expect(abs((stats.observedSampleRate ?? 0) - 24_000) < 1)
        #expect(stats.writtenSeconds < 1.1)
        #expect(stats.gapCount == 0)
        #expect(failures.withLock { $0.count } == 1)
    }

    @Test("正常なクロック・欠落・時刻リセットを速度異常と誤認しない")
    func clockResets() {
        var monitor = AudioClockMonitor()
        let t0 = HostClock.now()
        var host = 0.0
        var sample = 0.0
        for i in 0..<600 {
            if i == 130 { host += 0.3; sample += 7_200 }
            if i == 300 { host += 2; sample = 0 }
            let chunk = PCMChunk(channels: [Array(repeating: 0.1, count: 480)], sampleRate: 24_000,
                                 hostTime: t0 + HostClock.hostTime(fromSeconds: host), sampleTime: sample)
            #expect(monitor.observe(chunk) == nil)
            host += 0.02
            sample += 480
        }
        #expect(abs((monitor.observedSampleRate ?? 0) - 24_000) < 1)
    }

    @Test("48 → 24 → 48 kHz で WAV の長さ・音程とライブ時計を保つ")
    func rateChanges() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("system_16k.wav")
        let aac = root.appendingPathComponent("system.m4a")
        let t0 = HostClock.now()
        let pipeline = TrackPipeline(name: "system", timelineStartHostTime: t0, archiveURL: aac, sttURL: wav)
        let consumer = Task { () -> Double in
            var end = 0.0
            for await chunk in pipeline.chunks {
                #expect(abs(chunk.startTime - end) < 0.001)
                end = chunk.startTime + Double(chunk.samples.count) / chunk.sampleRate
            }
            return end
        }
        for (phase, rate) in [48_000.0, 24_000.0, 48_000.0].enumerated() {
            for i in 0..<20 {
                let frames = Int(rate / 10)
                let tone = (0..<frames).map { Float(0.25 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
                pipeline.enqueue(PCMChunk(channels: [tone], sampleRate: rate,
                                          hostTime: t0 + HostClock.hostTime(fromSeconds: Double(phase * 2) + Double(i) / 10), sampleTime: Double(i * frames)))
            }
        }
        let stats = pipeline.finish()
        #expect(stats.failure == nil)
        #expect(stats.formatChanges == 2)
        #expect(abs(stats.driftSeconds ?? 999) < 0.01)
        #expect(abs(try AudioFileTools.duration(of: wav) - 6) < 0.02)
        #expect(abs(try AudioFileTools.duration(of: aac) - 6) < 0.02)
        #expect(abs(await consumer.value - 6) < 0.02)
        let samples = try AudioFileTools.loadMono16k(wav)
        let crossings = zip(samples, samples.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
        #expect(abs(crossings - 2640) < 15)
    }

    @Test("実バッファの interleaved / planar を検証し、異なるレイアウトを拒否", arguments: [false, true])
    func bufferLayout(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for i in 0..<4 {
            if interleaved { buffer.floatChannelData![0][i * 2] = Float(i); buffer.floatChannelData![0][i * 2 + 1] = Float(-i) }
            else { buffer.floatChannelData![0][i] = Float(i); buffer.floatChannelData![1][i] = Float(-i) }
        }
        var info = ProcessTap.StreamInfo(sampleRate: 24_000, channels: 2, isNonInterleaved: !interleaved, isFloat: true, bitsPerChannel: 32, bufferIndex: 0, aggregateInputStreamCount: 1)
        #expect(try ProcessTap.decodeInput(buffer.audioBufferList, info: info) == [[0, 1, 2, 3], [0, -1, -2, -3]])
        info.bufferIndex = 2
        #expect(throws: AudioCaptureError.self) { try ProcessTap.decodeInput(buffer.audioBufferList, info: info) }
        info.bufferIndex = 0
        info.channels = 3
        #expect(throws: AudioCaptureError.self) { try ProcessTap.decodeInput(buffer.audioBufferList, info: info) }
    }

    @Test("機器入力の後ろの stereo tap を stream 数と buffer 数を混同せず特定")
    func aggregateLayout() throws {
        let monoFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let stereoFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 2, interleaved: false))
        let mono = withExtendedLifetime(monoFormat) { monoFormat.streamDescription.pointee }
        let stereo = withExtendedLifetime(stereoFormat) { stereoFormat.streamDescription.pointee }
        let oneStream = try ProcessTap.streamInfo(formats: [mono, stereo], tapChannels: 2)
        #expect(oneStream.bufferIndex == 1)
        #expect(oneStream.channels == 2)
        #expect(oneStream.isNonInterleaved)
        let split = try ProcessTap.streamInfo(formats: [stereo, mono, mono], tapChannels: 2)
        #expect(split.bufferIndex == 2)
        #expect(split.channels == 2)
        #expect(split.isNonInterleaved)
        #expect(throws: AudioCaptureError.self) { try ProcessTap.streamInfo(formats: [mono], tapChannels: 2) }
    }

    @Test("旧 manifest の半分の音声を正常とせず、空でない WAV でも STT 前に止める")
    func rejectLegacyRecording() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stats = brokenStats()
        var manifest = makeManifest(stats: stats)
        // 新 optional フィールドのない旧録音でも読み取れる。
        manifest.tracks["system"]?.observedSampleRate = nil
        try manifest.write(to: root)
        try AudioFileTools.writeWAV(samples: Array(repeating: 0.1, count: 48_000), sampleRate: 16_000, to: root.appendingPathComponent("system_16k.wav"))
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "bad clock", startedAt: Date(), privacyMode: .cloudOk, status: .finalizing, audioDir: root.path))
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: FakeTranscriber(id: "fake", runsLocally: true, segments: []), summarizer: nil, exportDirectory: root.appendingPathComponent("export")))
        // 2 秒の許容差を超える、本番同等の 2 倍のずれ。
        manifest.tracks["system"]?.lastChunkTimelineEnd = 100
        manifest.durationSeconds = 100
        try manifest.write(to: root)
        await #expect(throws: CaptureFailure.self) { try await pipeline.run(meetingId: meeting.id) }
        #expect(try store.latestRun(meetingId: meeting.id, step: "transcribe_final")?.runStatus == .invalidated)
        #expect(try store.latestRun(meetingId: meeting.id, step: "finalize_audio")?.runStatus == .failed)
        #expect(try store.meeting(id: meeting.id)?.meetingStatus == .failed)
        var healthy = stats
        healthy.lastChunkTimelineEnd = healthy.writtenSeconds
        try RecordingAudioValidation.validate(stats: healthy, fileDuration: 3, recordingDuration: 3.1)
        #expect(throws: CaptureFailure.self) { try RecordingAudioValidation.validate(stats: healthy, fileDuration: 30) }
    }

    @Test("回復は先頭無音を維持し、原本・既存出力を上書きしない")
    func repairCopy() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original")
        let output = root.appendingPathComponent("repaired")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let original = source.appendingPathComponent("system.m4a")
        let samples = Array(repeating: Float(0), count: 48_000) + (0..<96_000).map { Float(0.25 * sin(2 * Double.pi * 440 * Double($0) / 24_000)) }
        try AudioFileTools.writeAAC(samples: samples, sampleRate: 48_000, to: original, bitrate: 64_000)
        try makeManifest(stats: brokenStats()).write(to: source)
        let before = try Data(contentsOf: original)
        #expect(throws: AudioCaptureError.self) { try RecordingRateRepair.prepareCopy(source: source, destination: output, track: "system", actualSampleRate: 16_000) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try RecordingRateRepair.prepareCopy(source: source, destination: output, track: "system", actualSampleRate: 24_000)
        let repaired = try AudioFileTools.loadMono16k(output.appendingPathComponent("system_16k.wav"))
        #expect(abs(Double(repaired.count) / 16_000 - 5) < 0.02)
        #expect(AudioLevel.rmsDB(Array(repaired.prefix(15_000))) < -70)
        let crossings = zip(repaired.dropFirst(16_100), repaired.dropFirst(16_101)).filter { $0.0 <= 0 && $0.1 > 0 }.count
        #expect(abs(crossings - 1760) < 25)
        #expect(try Data(contentsOf: original) == before)
        #expect(try RecordingManifest.read(from: source).tracks["system"]?.sourceSampleRate == 48_000)
        #expect(throws: AudioCaptureError.self) { try RecordingRateRepair.prepareCopy(source: source, destination: output, track: "system", actualSampleRate: 24_000) }
    }

    private func brokenStats() -> TrackStatsSnapshot {
        TrackStatsSnapshot(name: "system", sourceSampleRate: 48_000, sourceChannels: 1, archiveSampleRate: 48_000,
                           receivedFrames: 96_000, receivedSeconds: 2, writtenSeconds: 3, firstChunkOffsetSeconds: 1,
                           gapCount: 0, gapSeconds: 0, overlapCount: 0, overlapSeconds: 0, formatChanges: 0,
                           lastRmsDb: -20, intervalPeakRmsDb: -20, activeSeconds: 2, lastChunkTimelineEnd: 5)
    }

    private func makeManifest(stats: TrackStatsSnapshot) -> RecordingManifest {
        RecordingManifest(schemaVersion: 1, id: UUID().uuidString, title: "test", startedAt: Date(), endedAt: Date(), durationSeconds: 5,
                          targetBundleIdentifiers: [], allSystemAudio: false, tappedProcesses: [], clockDevice: nil, micDevice: nil, tapStream: nil,
                          files: ["system_archive": "system.m4a", "system_stt": "system_16k.wav"], tracks: ["system": stats], resourceUsage: nil, events: [])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-clock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
