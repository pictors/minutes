import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// 入力デバイスの一覧用。
public struct AudioInputDevice: Sendable, Identifiable, Equatable {
    public var uid: String
    public var name: String
    public var isDefault: Bool
    public var id: String { uid }

    public init(uid: String, name: String, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
    }
}

/// 自分の声（mic track）。AVAudioEngine の inputNode を使い、デバイス切替を監視して再起動する（SPEC §4.2）。
/// `deviceUID` を指定すると inputNode の AudioUnit にそのデバイスを設定する（見つからなければシステムの既定入力）。
public final class MicCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "jp.pictors.minutes.mic.control")
    private var engine: AVAudioEngine?
    private var observer: (any NSObjectProtocol)?
    private var handler: (@Sendable (PCMChunk) -> Void)?
    private var pendingRestart: DispatchWorkItem?
    private var stopped = false
    public let deviceUID: String?
    public private(set) var currentFormat: AVAudioFormat?
    public private(set) var restartCount = 0
    /// 実際に使っている入力デバイス（指定が見つからず既定に戻った場合は既定の名前）。
    public private(set) var activeDeviceName: String?
    /// 指定デバイスを適用できたか。nil なら既定入力を使っている。
    public private(set) var activeDeviceUID: String?
    /// デバイス切替で再起動したときに呼ばれる（nil = 再起動失敗。続けて失敗しても最初の 1 回だけ呼ぶ）。
    public var onConfigurationChange: (@Sendable (AVAudioFormat?) -> Void)?
    /// 再起動に失敗したあと、停止までこの間隔で再試行する。マイクが戻れば録音に復帰する（SPEC §4.3）。
    private let retryInterval: TimeInterval
    /// 続けて失敗した再起動の回数（controlQueue でだけ触る）。
    private var failedRestarts = 0

    public init(deviceUID: String? = nil, retryInterval: TimeInterval = 3) {
        self.deviceUID = deviceUID?.isEmpty == true ? nil : deviceUID
        self.retryInterval = retryInterval
    }

    public static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static func defaultInputDeviceName() -> String? {
        AVCaptureDevice.default(for: .audio)?.localizedName
    }

    /// 入力ストリームを持つデバイス（設定の選択肢用）。既定入力に印を付ける。
    public static func inputDevices() -> [AudioInputDevice] {
        let system = AudioHardwareSystem.shared
        let defaultUID = try? system.defaultInputDevice?.uid
        let devices = (try? system.devices) ?? []
        return devices.compactMap { device -> AudioInputDevice? in
            let inputs = ((try? device.streams) ?? []).filter { (try? $0.direction) == .input }
            guard !inputs.isEmpty, let uid = try? device.uid else { return nil }
            return AudioInputDevice(uid: uid, name: (try? device.name) ?? uid, isDefault: uid == defaultUID)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func start(handler: @escaping @Sendable (PCMChunk) -> Void) throws {
        lock.withLock {
            self.handler = handler
            self.stopped = false
        }
        try startEngine()
    }

    public func stop() {
        lock.withLock { stopped = true }
        controlQueue.sync {
            pendingRestart?.cancel()
            pendingRestart = nil
        }
        teardownEngine()
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        var resolvedUID: String?
        var resolvedName: String?
        // 指定デバイスを inputNode の AudioUnit に設定する（形式の取得より前）。見つからなければ既定入力で続ける。
        if let deviceUID {
            if let device = try? AudioHardwareSystem.shared.device(forUID: deviceUID), let unit = input.audioUnit {
                var deviceID = device.id
                let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
                if status == noErr {
                    resolvedUID = deviceUID
                    resolvedName = (try? device.name) ?? deviceUID
                } else {
                    Log.audio.error("mic device \(deviceUID, privacy: .public) could not be selected (OSStatus \(status, privacy: .public)); using default input")
                }
            } else {
                Log.audio.error("mic device \(deviceUID, privacy: .public) not found; using default input")
            }
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, when in
            guard let self else { return }
            let hostTime = when.isHostTimeValid ? when.hostTime : 0
            let sampleTime = when.isSampleTimeValid ? Double(when.sampleTime) : Double.nan
            guard let chunk = PCMChunk(buffer: buffer, hostTime: hostTime, sampleTime: sampleTime) else { return }
            let handler = self.lock.withLock { self.handler }
            handler?(chunk)
        }
        engine.prepare()
        try engine.start()
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.scheduleRestart()
        }
        lock.withLock {
            self.engine = engine
            self.observer = observer
            self.currentFormat = format
            self.activeDeviceUID = resolvedUID
            self.activeDeviceName = resolvedName ?? MicCapture.defaultInputDeviceName()
        }
        Log.audio.info("mic engine started: \(Int(format.sampleRate), privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, device=\(resolvedName ?? "default", privacy: .public)")
    }

    private func teardownEngine() {
        let (engine, observer) = lock.withLock { (self.engine, self.observer) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.withLock {
            self.engine = nil
            self.observer = nil
        }
    }

    /// 切替直後は通知が連続するので 300 ms まとめてから再起動する。
    private func scheduleRestart(after delay: TimeInterval = 0.3) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            self.pendingRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.restart() }
            self.pendingRestart = work
            self.controlQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func restart() {
        if lock.withLock({ stopped }) { return }
        teardownEngine()
        lock.withLock { restartCount += 1 }
        do {
            try startEngine()
            failedRestarts = 0
            onConfigurationChange?(currentFormat)
        } catch {
            failedRestarts += 1
            Log.audio.error("mic engine restart failed (attempt \(self.failedRestarts, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            // 録音全体は止めない。最初の失敗だけ知らせ、停止まで一定間隔で再試行する（エンジンがないと切替の通知も来ない）。
            if failedRestarts == 1 { onConfigurationChange?(nil) }
            scheduleRestart(after: retryInterval)
        }
    }
}
