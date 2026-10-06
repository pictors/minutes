import CoreAudio
import Foundation
import Synchronization

/// デバイス操作を差し替え、切替中の停止・失敗も実機なしで検証できる境界。
protocol SystemAudioTap: AnyObject, Sendable {
    var clockDeviceID: AudioObjectID { get }
    var clockDeviceName: String { get }
    var streamInfo: ProcessTap.StreamInfo { get }
    var currentProcesses: [UInt32] { get }
    var onFailure: (@Sendable (CaptureFailure) -> Void)? { get set }
    var onLayoutObserved: (@Sendable (String) -> Void)? { get set }
    func start(handler: @escaping @Sendable (PCMChunk) -> Void) throws
    func setProcesses(_ ids: [UInt32]) throws
    func invalidate()
}

/// デバイス切替時に tap と aggregate を作り直す。ファイルと録音タイムラインは維持する。
/// 作り直しに失敗しても録音全体は止めず、停止まで一定間隔で再試行する（SPEC §4.3。止まり続けたかは watchdog が判断する）。
/// Core Audio の停止は IO コールバックと別のキューで行い、停止との競合を直列化する。
final class SystemAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jp.pictors.minutes.system.control")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let delivery = Mutex((generation: 0, accepting: false, firstChunk: true))
    private var configuration: ProcessTap.Configuration
    private let makeTap: @Sendable (ProcessTap.Configuration) throws -> any SystemAudioTap
    private let monitorDevices: Bool
    private let restartDelay: TimeInterval
    private let retryDelay: TimeInterval
    private var tap: (any SystemAudioTap)?
    private var handler: (@Sendable (PCMChunk) -> Void)?
    private var stopped = true
    private var pendingRestart: DispatchWorkItem?
    /// 続けて失敗した作り直しの回数。
    private var failedRestarts = 0
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    var onLayoutObserved: (@Sendable (String) -> Void)?
    var onEvent: (@Sendable (String) -> Void)?

    init(configuration: ProcessTap.Configuration, monitorDevices: Bool = true, restartDelay: TimeInterval = 0.3, retryDelay: TimeInterval = 3,
         makeTap: @escaping @Sendable (ProcessTap.Configuration) throws -> any SystemAudioTap = { try ProcessTap(configuration: $0) }) {
        self.configuration = configuration
        self.monitorDevices = monitorDevices
        self.restartDelay = restartDelay
        self.retryDelay = retryDelay
        self.makeTap = makeTap
        queue.setSpecific(key: queueKey, value: true)
    }

    private func onQueue<T>(_ action: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try action() }
        return try queue.sync(execute: action)
    }

    var clockDeviceName: String? { onQueue { tap?.clockDeviceName } }
    var streamInfo: ProcessTap.StreamInfo? { onQueue { tap?.streamInfo } }
    var currentProcesses: [UInt32] { onQueue { tap?.currentProcesses ?? configuration.processObjectIDs } }

    func start(handler: @escaping @Sendable (PCMChunk) -> Void) throws {
        try onQueue {
            guard stopped else { throw AudioCaptureError.invalidState("system 録音は既に開始しています") }
            self.handler = handler
            stopped = false
            do { try createTap() }
            catch { stopOnQueue(); throw error }
        }
    }

    func setProcesses(_ ids: [UInt32]) throws {
        try onQueue {
            guard !stopped else { return }
            try tap?.setProcesses(ids)
            configuration.processObjectIDs = ids
        }
    }

    /// マイク交渉・出力切替・クロック変更の通知をまとめる。
    func requestRestart(reason: String) {
        scheduleRestart(reason: reason, after: restartDelay)
    }

    private func scheduleRestart(reason: String, after delay: TimeInterval) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.delivery.withLock { $0.accepting = false }
            self.pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.stopped else { return }
                self.pendingRestart = nil
                self.releaseTap()
                do {
                    try self.createTap()
                    let retried = self.failedRestarts > 0 ? " after \(self.failedRestarts) failed attempts" : ""
                    self.failedRestarts = 0
                    self.onEvent?("system restarted after device change\(retried): \(reason), clock=\(self.tap?.clockDeviceName ?? "?"), \(self.tap?.streamInfo.description ?? "?")")
                } catch {
                    // 最初の失敗だけ記録し、停止まで一定間隔で作り直しを試みる。
                    self.failedRestarts += 1
                    if self.failedRestarts == 1 {
                        self.onEvent?("system restart failed: \(error.localizedDescription); retrying every \(Int(self.retryDelay)) s")
                    }
                    self.scheduleRestart(reason: reason, after: self.retryDelay)
                }
            }
            self.pendingRestart = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func createTap() throws {
        guard let handler else { throw AudioCaptureError.invalidState("system 音声の受信先がありません") }
        let tap = try makeTap(configuration)
        self.tap = tap
        let generation = delivery.withLock { state in
            state.generation += 1
            state.firstChunk = true
            state.accepting = true
            return state.generation
        }
        tap.onLayoutObserved = { [weak self] message in self?.onLayoutObserved?(message) }
        tap.onFailure = { [weak self] failure in
            self?.queue.async { [weak self] in
                guard let self, !self.stopped,
                      self.delivery.withLock({ $0.generation == generation && $0.accepting }) else { return }
                // 録音全体は止めない（SPEC §4.3）。tap を作り直す。
                self.onEvent?("system tap failed: \(failure.localizedDescription); recreating")
                self.requestRestart(reason: "tap failure")
            }
        }
        if monitorDevices {
            try watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, reason: "default output")
            try watch(tap.clockDeviceID, kAudioDevicePropertyNominalSampleRate, reason: "clock sample rate")
            try watch(tap.clockDeviceID, kAudioDevicePropertyDeviceIsAlive, reason: "clock availability")
        }
        try tap.start { [weak self] input in
            guard let self else { return }
            let first = self.delivery.withLock { state -> Bool? in
                guard state.accepting, state.generation == generation else { return nil }
                let first = state.firstChunk
                state.firstChunk = false
                return first
            }
            guard let first else { return }
            var chunk = input
            // 新しい tap のサンプル番号は旧 tap と比較できない。先頭だけホスト時計で接続する。
            if first { chunk.sampleTime = .nan }
            handler(chunk)
        }
        onEvent?("system clock: \(tap.clockDeviceName), \(tap.streamInfo)")
    }

    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, reason: String) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let generation = delivery.withLock { $0.generation }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.delivery.withLock({ $0.generation == generation }) else { return }
            self.requestRestart(reason: reason)
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else { throw AudioCaptureError.ioProcFailed(status) }
        listeners.append((object, address, block))
    }

    private func releaseTap() {
        delivery.withLock { $0.accepting = false; $0.generation += 1 }
        for (object, originalAddress, block) in listeners {
            var address = originalAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listeners.removeAll()
        tap?.invalidate()
        tap = nil
    }

    private func stopOnQueue() {
        stopped = true
        pendingRestart?.cancel()
        pendingRestart = nil
        releaseTap()
        handler = nil
    }

    func stop() { onQueue { stopOnQueue() } }
    func invalidate() { stop() }
    deinit { stop() }
}
