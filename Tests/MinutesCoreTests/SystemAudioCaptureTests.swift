import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import MinutesCore

private final class FakeSystemTap: SystemAudioTap, @unchecked Sendable {
    let clockDeviceID: AudioObjectID = 1
    let clockDeviceName = "Built-in"
    let streamInfo = ProcessTap.StreamInfo(sampleRate: 48_000, channels: 1, isNonInterleaved: true, isFloat: true, bitsPerChannel: 32, bufferIndex: 0, aggregateInputStreamCount: 1)
    let configuration: ProcessTap.Configuration
    let state = Mutex((handler: Optional<@Sendable (PCMChunk) -> Void>.none, invalidations: 0, processes: [UInt32]()))
    var onFailure: (@Sendable (CaptureFailure) -> Void)?
    var onLayoutObserved: (@Sendable (String) -> Void)?
    var currentProcesses: [UInt32] { state.withLock { $0.processes } }
    init(configuration: ProcessTap.Configuration) {
        self.configuration = configuration
        state.withLock { $0.processes = configuration.processObjectIDs }
    }
    func start(handler: @escaping @Sendable (PCMChunk) -> Void) throws { state.withLock { $0.handler = handler } }
    func setProcesses(_ ids: [UInt32]) throws { state.withLock { $0.processes = ids } }
    // handler を残し、破棄された tap から遅れて届くコールバックも検証する。
    func invalidate() { state.withLock { $0.invalidations += 1 } }
    func emit(_ chunk: PCMChunk) { state.withLock { $0.handler }?(chunk) }
}

@Suite("system 音声のクロック選択と再接続")
struct SystemAudioCaptureTests {
    @Test("入出力が分離した Bluetooth / BLE より内蔵クロックを優先", arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE])
    func splitBluetoothClock(transport: UInt32) {
        let candidates: [AudioClockDeviceSelection.Candidate] = [
            .init(id: 101, transportType: transport, inputStreams: 1, outputStreams: 0),
            .init(id: 95, transportType: transport, inputStreams: 0, outputStreams: 1),
            .init(id: 90, transportType: kAudioDeviceTransportTypeBuiltIn, inputStreams: 1, outputStreams: 0),
            .init(id: 83, transportType: kAudioDeviceTransportTypeBuiltIn, inputStreams: 0, outputStreams: 1),
        ]
        #expect(AudioClockDeviceSelection.select(from: candidates, defaultOutputID: 95) == 83)
        #expect(AudioClockDeviceSelection.select(from: candidates.reversed(), defaultOutputID: 95) == 83)
    }

    @Test("内蔵がなければ有線を使い、停止中・入力専用のデバイスは除外")
    func fallbackClock() {
        let candidates: [AudioClockDeviceSelection.Candidate] = [
            .init(id: 1, transportType: kAudioDeviceTransportTypeBuiltIn, inputStreams: 0, outputStreams: 1, isAlive: false),
            .init(id: 2, transportType: kAudioDeviceTransportTypeBuiltIn, inputStreams: 1, outputStreams: 0),
            .init(id: 3, transportType: kAudioDeviceTransportTypeUSB, inputStreams: 1, outputStreams: 1),
            .init(id: 4, transportType: kAudioDeviceTransportTypeBluetooth, inputStreams: 0, outputStreams: 1),
        ]
        #expect(AudioClockDeviceSelection.select(from: candidates, defaultOutputID: 4) == 3)
        #expect(AudioClockDeviceSelection.select(from: Array(candidates.suffix(1)), defaultOutputID: 4) == 4)
        #expect(AudioClockDeviceSelection.select(from: Array(candidates.prefix(2)), defaultOutputID: 1) == nil)
    }

    @Test("再接続後も対象プロセスを維持し、サンプル番号のリセットを重複音声と扱わない")
    func restartTimeline() async throws {
        let taps = Mutex<[FakeSystemTap]>([])
        var configuration = ProcessTap.Configuration()
        configuration.processObjectIDs = [10]
        configuration.bundleIDs = ["test.meeting"]
        configuration.clockDeviceUID = "explicit-clock"
        let capture = SystemAudioCapture(configuration: configuration, monitorDevices: false, restartDelay: 0, makeTap: { config in
            let tap = FakeSystemTap(configuration: config)
            taps.withLock { $0.append(tap) }
            return tap
        })
        defer { capture.stop() }
        let t0 = HostClock.now()
        let pipeline = TrackPipeline(name: "system", timelineStartHostTime: t0, archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        let restarts = Mutex(0)
        capture.onEvent = { if $0.hasPrefix("system restarted") { restarts.withLock { $0 += 1 } } }
        try capture.start { pipeline.enqueue($0) }
        let first = try #require(taps.withLock { $0.first })
        for i in 0..<30 { first.emit(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800))) }
        try capture.setProcesses([10, 20])
        capture.requestRestart(reason: "microphone configuration")
        try await waitUntil { restarts.withLock { $0 == 1 } }
        let second = try #require(taps.withLock { $0.last })
        #expect(second !== first)
        #expect(second.configuration.processObjectIDs == [10, 20])
        #expect(second.configuration.bundleIDs == ["test.meeting"])
        #expect(second.configuration.clockDeviceUID == "explicit-clock")
        #expect(first.state.withLock { $0.invalidations } == 1)
        // 古い tap から遅れた音声は無視。新しい tap の sampleTime は 0 に戻る。
        first.emit(chunk(t0: t0, time: 3, sample: 144_000))
        for i in 0..<30 { second.emit(chunk(t0: t0, time: 3.3 + Double(i) / 10, sample: Double(i * 4800))) }
        capture.stop()
        let stats = pipeline.finish()
        #expect(stats.failure == nil)
        #expect(stats.receivedFrames == 60 * 4800)
        #expect(stats.overlapCount == 0)
        #expect(stats.gapCount == 1)
        #expect(abs(stats.gapSeconds - 0.3) < 0.001)
        #expect(abs(stats.writtenSeconds - 6.3) < 0.001)
        #expect(abs(stats.driftSeconds ?? 99) < 0.001)
    }

    @Test("停止が再接続待ちを取り消し、遅れた通知でも録音を再開しない")
    func stopCancelsRestart() async throws {
        let count = Mutex(0)
        let capture = SystemAudioCapture(configuration: .init(), monitorDevices: false, restartDelay: 0.02, makeTap: { config in
            count.withLock { $0 += 1 }
            return FakeSystemTap(configuration: config)
        })
        try capture.start { _ in }
        capture.requestRestart(reason: "output")
        capture.stop()
        capture.requestRestart(reason: "late notification")
        try await Task.sleep(for: .milliseconds(50))
        #expect(count.withLock { $0 } == 1)
    }

    @Test("作り直しに失敗しても録音を止めず、一定間隔で再試行して戻る（SPEC §4.3）")
    func restartFailureRetries() async throws {
        let count = Mutex(0)
        let events = Mutex<[String]>([])
        let capture = SystemAudioCapture(configuration: .init(), monitorDevices: false, restartDelay: 0, retryDelay: 0.01, makeTap: { config in
            let attempt = count.withLock { $0 += 1; return $0 }
            if attempt == 2 || attempt == 3 { throw AudioCaptureError.noInputDevice }
            return FakeSystemTap(configuration: config)
        })
        defer { capture.stop() }
        capture.onEvent = { event in events.withLock { $0.append(event) } }
        try capture.start { _ in }
        capture.requestRestart(reason: "output")
        try await waitUntil { events.withLock { $0.contains { $0.hasPrefix("system restarted") } } }
        #expect(count.withLock { $0 } == 4)
        // 失敗の記録は続けて失敗しても 1 回だけ
        #expect(events.withLock { $0.filter { $0.hasPrefix("system restart failed") }.count } == 1)
        #expect(events.withLock { $0.contains { $0.contains("after 2 failed attempts") } })
    }

    @Test("停止すると失敗後の再試行も止まる")
    func stopCancelsRetries() async throws {
        let count = Mutex(0)
        let capture = SystemAudioCapture(configuration: .init(), monitorDevices: false, restartDelay: 0, retryDelay: 0.01, makeTap: { config in
            let attempt = count.withLock { $0 += 1; return $0 }
            if attempt > 1 { throw AudioCaptureError.noInputDevice }
            return FakeSystemTap(configuration: config)
        })
        try capture.start { _ in }
        capture.requestRestart(reason: "output")
        try await waitUntil { count.withLock { $0 >= 3 } }
        capture.stop()
        let attempts = count.withLock { $0 }
        try await Task.sleep(for: .milliseconds(60))
        #expect(count.withLock { $0 } == attempts)
    }

    private func chunk(t0: UInt64, time: Double, sample: Double) -> PCMChunk {
        PCMChunk(channels: [Array(repeating: 0.1, count: 4800)], sampleRate: 48_000,
                 hostTime: t0 + HostClock.hostTime(fromSeconds: time), sampleTime: sample)
    }

    private func waitUntil(_ ready: @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("再接続の完了通知が届きません")
    }
}
