import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import MinutesCore

/// 作り直しの途中で止まる tap を試すための、実機を使わない tap。
private final class StopTestTap: SystemAudioTap, @unchecked Sendable {
    let clockDeviceID: AudioObjectID = 1
    let clockDeviceName = "テスト用の出力"
    let streamInfo = ProcessTap.StreamInfo(sampleRate: 48_000, channels: 1, isNonInterleaved: true, isFloat: true, bitsPerChannel: 32, bufferIndex: 0, aggregateInputStreamCount: 1)
    let currentProcesses: [UInt32] = []
    private let state = Mutex((handler: Optional<@Sendable (PCMChunk) -> Void>.none, invalidations: 0))
    var onFailure: (@Sendable (CaptureFailure) -> Void)?
    var onLayoutObserved: (@Sendable (String) -> Void)?
    var invalidations: Int { state.withLock { $0.invalidations } }
    func start(handler: @escaping @Sendable (PCMChunk) -> Void) throws { state.withLock { $0.handler = handler } }
    func setProcesses(_ ids: [UInt32]) throws {}
    // handler を残し、閉じた tap から遅れて届く音声も試せるようにする。
    func invalidate() { state.withLock { $0.invalidations += 1 } }
    func emit(_ chunk: PCMChunk) { state.withLock { $0.handler }?(chunk) }
}

@Suite("録音の停止（入力の停止が戻らないとき）")
struct RecordingStopTests {
    @Test("戻らない入力があっても待ち時間で戻り、もう片方の入力は止める")
    func boundedStop() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let stopped = Mutex<[String]>([])
        let started = HostClock.nowSeconds()
        let unfinished = CaptureStop.run([
            .init(name: "system") { gate.wait(); stopped.withLock { $0.append("system") } },
            .init(name: "mic") { stopped.withLock { $0.append("mic") } },
        ], timeout: 0.2)
        #expect(HostClock.nowSeconds() - started < 1)
        #expect(unfinished == ["system"])
        #expect(stopped.withLock { $0 } == ["mic"])
        // 戻らなかった停止は裏で続き、戻ったところで終わる
        gate.signal()
        try await waitUntil { stopped.withLock { $0.count == 2 } }
    }

    @Test("すぐ止まる入力だけなら、待ち時間いっぱいは待たない")
    func quickStop() {
        let started = HostClock.nowSeconds()
        let unfinished = CaptureStop.run([.init(name: "system") {}, .init(name: "mic") {}], timeout: 5)
        #expect(unfinished.isEmpty)
        #expect(HostClock.nowSeconds() - started < 1)
    }

    @Test("停止を求めた時点より後に始まる音声は書かず、途切れていたトラックはその時点まで埋める")
    func pipelineEnd() throws {
        let t0 = HostClock.now()
        let healthy = TrackPipeline(name: "system", timelineStartHostTime: t0, archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        let unbounded = TrackPipeline(name: "system", timelineStartHostTime: t0, archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        let stalled = TrackPipeline(name: "mic", timelineStartHostTime: t0, archiveURL: nil, sttURL: nil, streamLiveAudio: false)
        // system は 0〜5 秒、mic は 2 秒で止まっている
        for i in 0..<50 {
            healthy.enqueue(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800)))
            unbounded.enqueue(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800)))
        }
        for i in 0..<20 { stalled.enqueue(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800))) }
        // 5.05 秒に停止を求めた。入力の停止を待つ間も system の音声が 5 秒分届く
        let end = 5.05
        healthy.end(at: end)
        stalled.end(at: end)
        for i in 50..<100 {
            healthy.enqueue(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800)))
            unbounded.enqueue(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800)))
        }
        let system = healthy.finish(padTo: end)
        let mic = stalled.finish(padTo: end)

        // 停止をまたぐ 5.0 秒からの音声までを書く
        #expect(system.receivedFrames == 51 * 4800)
        #expect(abs(system.writtenSeconds - 5.1) < 0.001)
        #expect(abs((system.lastChunkTimelineEnd ?? 0) - 5.1) < 0.001)
        #expect(system.tailPaddingSeconds == nil)
        #expect(abs(mic.writtenSeconds - end) < 0.01)
        #expect(abs((mic.tailPaddingSeconds ?? 0) - 3.05) < 0.01)
        try RecordingAudioValidation.validate(stats: system, recordingDuration: end)
        try RecordingAudioValidation.validate(stats: mic, recordingDuration: end)
        // 待つ間に届いた音声まで書くと録音の長さと合わず、後処理の「音声の確認」で止まる
        #expect(throws: CaptureFailure.self) { try RecordingAudioValidation.validate(stats: unbounded.finish(padTo: end), recordingDuration: end) }
    }

    @Test("tap の作り直しが戻らないうちに止めても、止める側は待ち時間で戻り、遅れて作られた tap は閉じる")
    func stuckTapRestart() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let taps = Mutex<[StopTestTap]>([])
        let capture = SystemAudioCapture(configuration: .init(), monitorDevices: false, restartDelay: 0, makeTap: { _ in
            let tap = StopTestTap()
            // 2 回目（機器の切り替えによる作り直し）は Core Audio の中で戻らない
            if taps.withLock({ $0.append(tap); return $0.count }) == 2 { gate.wait() }
            return tap
        })
        let received = Mutex(0)
        try capture.start { _ in received.withLock { $0 += 1 } }
        capture.requestRestart(reason: "default output")
        try await waitUntil { taps.withLock { $0.count == 2 } }

        let started = HostClock.nowSeconds()
        let unfinished = CaptureStop.run([.init(name: "system") { capture.stop() }], timeout: 0.2)
        #expect(HostClock.nowSeconds() - started < 1)
        #expect(unfinished == ["system"])

        // 作り直しが戻ると、待っていた停止が作られた tap を閉じる（録音を再開しない）
        gate.signal()
        let late = try #require(taps.withLock { $0.last })
        try await waitUntil { late.invalidations == 1 }
        late.emit(chunk(t0: HostClock.now(), time: 0, sample: 0))
        #expect(received.withLock { $0 } == 0)
    }

    @Test("作り直しが戻らないまま録音を止めても、停止は待ち時間で終わり、録音の長さと終了時刻は止めた時点まで")
    func sessionStopDuringStuckRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = RecordingOptions(outputDirectory: directory)
        options.includeMic = false
        options.allSystemAudio = true
        options.streamLiveAudio = false
        options.followNewProcesses = false
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let taps = Mutex<[StopTestTap]>([])
        let session = RecordingSession(options: options)
        session.inputStopTimeout = 0.3
        session.makeSystemCapture = { configuration in
            SystemAudioCapture(configuration: configuration, monitorDevices: false, restartDelay: 0, makeTap: { _ in
                let tap = StopTestTap()
                if taps.withLock({ $0.append(tap); return $0.count }) == 2 { gate.wait() }
                return tap
            })
        }
        try await session.start()
        let t0 = session.timelineStartHostTime
        try await Task.sleep(for: .milliseconds(500))
        let first = try #require(taps.withLock { $0.first })
        for i in 0..<5 { first.emit(chunk(t0: t0, time: Double(i) / 10, sample: Double(i * 4800))) }
        // 音声が止まり、tap を作り直そうとして Core Audio の中で戻らなくなった
        first.onFailure?(CaptureFailure(track: "system", operation: "テスト", message: "tap が止まった"))
        try await waitUntil { taps.withLock { $0.count == 2 } }

        // 直す前は、作り直しが戻るまで stop() が戻らなかった（ここでは 2 秒後に戻す。実機では Mac が次に起きるまで）
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { gate.signal() }
        let requestedAt = Date()
        let requested = HostClock.nowSeconds() - HostClock.seconds(fromHostTime: t0)
        let manifest = try session.stop()
        let returned = HostClock.nowSeconds() - HostClock.seconds(fromHostTime: t0)
        gate.signal()

        #expect(returned - requested < 1.5)
        let duration = try #require(manifest.durationSeconds)
        #expect(abs(duration - requested) < 0.2)
        #expect(abs((manifest.endedAt ?? .distantFuture).timeIntervalSince(requestedAt)) < 0.2)
        #expect(manifest.events.contains { $0.contains("system did not stop within") })
        #expect(manifest.clockDevice == "テスト用の出力")
        let system = try #require(manifest.tracks["system"])
        #expect(system.failure == nil)
        #expect(abs((system.lastChunkTimelineEnd ?? 0) - 0.5) < 0.001)
        #expect(try RecordingManifest.read(from: directory).durationSeconds == duration)

        // 作り直しが戻ったあと、作られた tap は閉じる
        let late = try #require(taps.withLock { $0.last })
        try await waitUntil { late.invalidations == 1 }
    }

    // MARK: - Helpers

    private func chunk(t0: UInt64, time: Double, sample: Double) -> PCMChunk {
        PCMChunk(channels: [Array(repeating: 0.1, count: 4800)], sampleRate: 48_000,
                 hostTime: t0 + HostClock.hostTime(fromSeconds: time), sampleTime: sample)
    }

    private func waitUntil(_ ready: @Sendable () -> Bool) async throws {
        for _ in 0..<400 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("待っている状態になりません")
    }
}
