import AVFoundation
import CoreAudio
import Foundation

/// Core Audio Process Tap（macOS 14.2+）で会議アプリの出力音声を取得する（SPEC §4.1）。
/// 手順: CATapDescription → makeProcessTap → tap を含む private な aggregate device → IOProc で読み出し。
/// 参照実装: insidegui/AudioCap。macOS 26 では `bundleIDs` + `processRestoreEnabled` で
/// 起動後に現れる helper プロセスにも追従する。
@available(macOS 15.0, *)
public final class ProcessTap: SystemAudioTap, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var processObjectIDs: [UInt32] = []
        /// macOS 26: bundle id でも対象を指定し、プロセス再起動時に復元する。
        public var bundleIDs: [String] = []
        /// true なら「列挙したプロセス以外の全システム音声」を取る（--all-system-audio）。
        public var excludeListedProcesses = false
        public var stereo = true
        public var muteBehavior: CATapMuteBehavior = .unmuted
        /// true にすると対象プロセスが音を出すまで IO が始まらない（タイムラインが遅れて始まる）。
        public var tapAutoStart = false
        /// aggregate のクロックに使う出力デバイスの UID。nil なら自動選択。
        public var clockDeviceUID: String?
        public var name = "Minutes Tap"

        public init() {}
    }

    public struct StreamInfo: Sendable, Equatable, CustomStringConvertible {
        public var sampleRate: Double
        public var channels: Int
        public var isNonInterleaved: Bool
        public var isFloat: Bool
        public var bitsPerChannel: Int
        /// aggregate の入力 AudioBufferList 内で tap のデータが始まるバッファ index。
        public var bufferIndex: Int
        public var aggregateInputStreamCount: Int

        public var description: String {
            "\(Int(sampleRate)) Hz, \(channels) ch, \(isFloat ? "float" : "int")\(bitsPerChannel), \(isNonInterleaved ? "planar" : "interleaved"), bufferIndex=\(bufferIndex)/\(aggregateInputStreamCount)"
        }
    }

    public let configuration: Configuration
    public let clockDeviceUID: String
    public let clockDeviceName: String
    var clockDeviceID: AudioObjectID { clock.id }
    public var streamInfo: StreamInfo { stateLock.withLock { currentStreamInfo } }
    private var currentStreamInfo: StreamInfo
    public let tapFormat: AudioStreamBasicDescription

    private let system = AudioHardwareSystem.shared
    private let tap: AudioHardwareTap
    private let aggregate: AudioHardwareAggregateDevice
    private let clock: AudioHardwareDevice
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "jp.pictors.minutes.processtap.io", qos: .userInteractive)
    private let ioQueueKey = DispatchSpecificKey<Bool>()
    private let stateLock = NSLock()
    private var handler: (@Sendable (PCMChunk) -> Void)?
    private var invalidated = false
    // 以下は ioQueue 上でのみ操作。形式通知と IO を同じキューで直列化する。
    private var needsFormatRefresh = true
    private var lastFormatCheck = 0.0
    private var failed = false
    private var propertyListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var watchedStreams: [AudioObjectID] = []
    public var onFailure: (@Sendable (CaptureFailure) -> Void)?
    private var observedBufferCount = -1
    public var onLayoutObserved: (@Sendable (String) -> Void)?

    public init(configuration: Configuration) throws {
        self.configuration = configuration
        let description = ProcessTap.makeDescription(configuration)
        let tap: AudioHardwareTap
        do {
            guard let created = try system.makeProcessTap(description: description) else {
                throw AudioCaptureError.tapCreationFailed("makeProcessTap が nil を返しました")
            }
            tap = created
        } catch let error as AudioCaptureError {
            throw error
        } catch {
            throw AudioCaptureError.tapCreationFailed("\(error)")
        }
        self.tap = tap
        do {
            tapFormat = try tap.format
        } catch {
            try? system.destroyProcessTap(tap)
            throw AudioCaptureError.tapCreationFailed("tap の形式を取得できません: \(error)")
        }

        let clock: AudioHardwareDevice
        do {
            clock = try ProcessTap.selectClockDevice(preferredUID: configuration.clockDeviceUID)
            self.clock = clock
            clockDeviceUID = try clock.uid
            clockDeviceName = (try? clock.name) ?? clockDeviceUID
        } catch {
            try? system.destroyProcessTap(tap)
            throw error
        }

        let tapUID: String
        do { tapUID = try tap.uid } catch {
            try? system.destroyProcessTap(tap)
            throw AudioCaptureError.tapCreationFailed("tap UID を取得できません: \(error)")
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: configuration.name,
            kAudioAggregateDeviceUIDKey: "jp.pictors.minutes.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: configuration.tapAutoStart,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockDeviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUID,
            ]],
        ]
        do {
            guard let aggregate = try system.makeAggregateDevice(description: composition) else {
                throw AudioCaptureError.aggregateCreationFailed("makeAggregateDevice が nil を返しました")
            }
            self.aggregate = aggregate
        } catch let error as AudioCaptureError {
            try? system.destroyProcessTap(tap)
            throw error
        } catch {
            try? system.destroyProcessTap(tap)
            throw AudioCaptureError.aggregateCreationFailed("\(error)")
        }
        do {
            currentStreamInfo = try ProcessTap.computeStreamInfo(aggregate: aggregate, tapChannels: Int(tap.format.mChannelsPerFrame))
        } catch {
            try? system.destroyAggregateDevice(aggregate)
            try? system.destroyProcessTap(tap)
            throw error
        }
        ioQueue.setSpecific(key: ioQueueKey, value: true)
    }

    deinit {
        invalidate()
    }

    // MARK: - Description

    static func makeDescription(_ configuration: Configuration) -> CATapDescription {
        let ids = configuration.processObjectIDs.map { AudioObjectID($0) }
        let description: CATapDescription
        if configuration.excludeListedProcesses {
            description = configuration.stereo
                ? CATapDescription(stereoGlobalTapButExcludeProcesses: ids)
                : CATapDescription(monoGlobalTapButExcludeProcesses: ids)
        } else {
            description = configuration.stereo
                ? CATapDescription(stereoMixdownOfProcesses: ids)
                : CATapDescription(monoMixdownOfProcesses: ids)
        }
        description.name = configuration.name
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = configuration.muteBehavior
        if !configuration.excludeListedProcesses, !configuration.bundleIDs.isEmpty {
            description.bundleIDs = configuration.bundleIDs
            description.isProcessRestoreEnabled = true
        }
        return description
    }

    /// 再生先とは独立した安定したクロックを選ぶ。AirPods は入力と出力が別デバイスに
    /// 分かれるため、「入力がない」だけでは通話モードのレート変更を避けられない。
    static func selectClockDevice(preferredUID: String?) throws -> AudioHardwareDevice {
        let system = AudioHardwareSystem.shared
        if let preferredUID {
            guard let device = try system.device(forUID: preferredUID) else {
                throw AudioCaptureError.aggregateCreationFailed("デバイス UID \(preferredUID) が見つかりません")
            }
            return device
        }
        let devices = try system.devices
        let candidates = devices.compactMap { device -> AudioClockDeviceSelection.Candidate? in
            // 読み取り失敗を「入力なし」とみなして採用しない。
            guard (try? device.canBeDefaultOutputDevice) == true,
                  let streams = try? device.streams,
                  let directions = try? streams.map({ try $0.direction }),
                  let transport = try? device.transportType,
                  let alive = try? device.isAlive else { return nil }
            return .init(id: device.id, transportType: transport,
                         inputStreams: directions.filter { $0 == .input }.count,
                         outputStreams: directions.filter { $0 == .output }.count, isAlive: alive)
        }
        let selected = AudioClockDeviceSelection.select(from: candidates, defaultOutputID: try? system.defaultOutputDevice?.id)
        guard let device = devices.first(where: { $0.id == selected }) else {
            throw AudioCaptureError.aggregateCreationFailed("利用可能な出力クロックがありません")
        }
        return device
    }

    static func inputStreamCount(of device: AudioHardwareDevice) -> Int {
        ((try? device.streams) ?? []).filter { (try? $0.direction) == .input }.count
    }

    static func outputStreamCount(of device: AudioHardwareDevice) -> Int {
        ((try? device.streams) ?? []).filter { (try? $0.direction) == .output }.count
    }

    static func bufferCount(for format: AudioStreamBasicDescription) -> Int {
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        return nonInterleaved ? max(1, Int(format.mChannelsPerFrame)) : 1
    }

    /// IOProc のデータ形式は tap 作成時の format ではなく、aggregate の現在の virtualFormat。
    /// SDK AudioHardwareBase.h の kAudioStreamPropertyVirtualFormat を確認（2026-09-19）。
    /// sub-device の入力が先、mixdown tap が後。stereo が mono stream 2 本になる構成も扱う。
    static func computeStreamInfo(aggregate: AudioHardwareAggregateDevice, tapChannels: Int) throws -> StreamInfo {
        let inputs = try aggregate.streams.filter { try $0.direction == .input }
        return try streamInfo(formats: inputs.map { try $0.virtualFormat }, tapChannels: tapChannels)
    }

    static func streamInfo(formats: [AudioStreamBasicDescription], tapChannels: Int) throws -> StreamInfo {
        var first = formats.count
        var channels = 0
        while first > 0, channels < tapChannels {
            first -= 1
            channels += Int(formats[first].mChannelsPerFrame)
        }
        guard tapChannels > 0, channels == tapChannels, first < formats.count else {
            throw AudioCaptureError.conversionFailed("aggregate の tap 入力構成を特定できません")
        }
        let format = formats[first]
        let tapFormats = formats[first...]
        let separateMono = tapFormats.count > 1 && tapFormats.allSatisfy { $0.mChannelsPerFrame == 1 }
        guard format.mSampleRate.isFinite, format.mSampleRate > 0,
              tapFormats.count == 1 || separateMono,
              tapFormats.allSatisfy({ $0.mSampleRate == format.mSampleRate && $0.mFormatID == kAudioFormatLinearPCM && $0.mBitsPerChannel == 32 && $0.mFormatFlags & kAudioFormatFlagIsFloat != 0 }) else {
            throw AudioCaptureError.conversionFailed("aggregate の音声形式が無効、または不一致です")
        }
        let index = formats.prefix(first).reduce(0) { $0 + bufferCount(for: $1) }
        return StreamInfo(
            sampleRate: format.mSampleRate,
            channels: channels,
            isNonInterleaved: separateMono || format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
            isFloat: format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
            bitsPerChannel: Int(format.mBitsPerChannel),
            bufferIndex: index,
            aggregateInputStreamCount: formats.count
        )
    }

    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.needsFormatRefresh = true
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, ioQueue, block)
        guard status == noErr else { throw AudioCaptureError.ioProcFailed(status) }
        propertyListeners.append((object, address, block))
    }

    private func removeFormatListeners() {
        for (object, originalAddress, block) in propertyListeners {
            var address = originalAddress
            AudioObjectRemovePropertyListenerBlock(object, &address, ioQueue, block)
        }
        propertyListeners.removeAll()
        watchedStreams.removeAll()
    }

    private func refreshFormat() throws {
        let streams = try aggregate.streams.filter { try $0.direction == .input }.map(\.id)
        if propertyListeners.isEmpty || streams != watchedStreams {
            removeFormatListeners()
            do {
                try watch(aggregate.id, kAudioDevicePropertyStreams)
                try watch(aggregate.id, kAudioDevicePropertyNominalSampleRate)
                try watch(tap.id, kAudioTapPropertyFormat)
                try watch(clock.id, kAudioDevicePropertyNominalSampleRate)
                for stream in streams { try watch(stream, kAudioStreamPropertyVirtualFormat) }
                watchedStreams = streams
            } catch {
                removeFormatListeners()
                throw error
            }
        }
        let updated = try Self.computeStreamInfo(aggregate: aggregate, tapChannels: Int(tap.format.mChannelsPerFrame))
        let old = stateLock.withLock { () -> StreamInfo in
            let old = currentStreamInfo
            currentStreamInfo = updated
            return old
        }
        if updated != old { onLayoutObserved?("format changed: \(old) → \(updated)") }
        needsFormatRefresh = false
        lastFormatCheck = HostClock.nowSeconds()
    }

    private func failCapture(_ error: any Error) {
        guard !failed else { return }
        failed = true
        let failure = CaptureFailure(track: "system", operation: "録音形式の更新", message: error.localizedDescription)
        Log.audio.error("\(failure.localizedDescription, privacy: .public)")
        onFailure?(failure)
    }

    // MARK: - IO

    public func start(handler: @escaping @Sendable (PCMChunk) -> Void) throws {
        stateLock.withLock { self.handler = handler }
        try ioQueue.sync {
            failed = false
            try refreshFormat()
            // start 後、最初の IO でも再取得する（起動時の形式交渉を考慮）。
            needsFormatRefresh = true
        }
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            self?.handleIO(inputData: inputData, inputTime: inputTime)
        }
        guard status == noErr, let procID else { throw AudioCaptureError.ioProcFailed(status) }
        ioProcID = procID
        do {
            try aggregate.start(IOProcID: procID)
        } catch {
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
            ioProcID = nil
            throw AudioCaptureError.tapCreationFailed("aggregate device を開始できません: \(error)")
        }
    }

    public func stop() {
        stateLock.lock()
        let procID = ioProcID
        ioProcID = nil
        stateLock.unlock()
        if let procID {
            try? aggregate.stop(IOProcID: procID)
            AudioDeviceDestroyIOProcID(aggregate.id, procID)
        }
        if DispatchQueue.getSpecific(key: ioQueueKey) == true { removeFormatListeners() }
        else { ioQueue.sync { removeFormatListeners() } }
    }

    /// tap / aggregate を破棄する。以後このインスタンスは使えない。
    public func invalidate() {
        stop()
        stateLock.lock()
        let already = invalidated
        invalidated = true
        stateLock.unlock()
        guard !already else { return }
        try? system.destroyAggregateDevice(aggregate)
        try? system.destroyProcessTap(tap)
    }

    /// tap の対象プロセスを差し替える（kAudioTapPropertyDescription は変更可能）。
    public func setProcesses(_ ids: [UInt32]) throws {
        let description = try tap.description
        description.processes = ids.map { AudioObjectID($0) }
        try tap.setDescription(description)
    }

    public var currentProcesses: [UInt32] {
        ((try? tap.description.processes) ?? []).map { UInt32($0) }
    }

    private func handleIO(inputData: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>) {
        guard !failed else { return }
        do {
            // 通知に加えて定期照合。バッファ形式不明時に古い設定で読み続けない。
            if needsFormatRefresh || HostClock.nowSeconds() - lastFormatCheck >= 1 { try refreshFormat() }
            var info = streamInfo
            let channels: [[Float]]
            do { channels = try Self.decodeInput(inputData, info: info) }
            catch {
                // 形式通知より先に新レイアウトの IO が来た場合は、その場で再照合する。
                try refreshFormat()
                info = streamInfo
                channels = try Self.decodeInput(inputData, info: info)
            }
            guard let frames = channels.first?.count, frames > 0 else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            if observedBufferCount != list.count {
                observedBufferCount = list.count
                onLayoutObserved?("aggregate input buffers=\(list.count), bytes=\(list[info.bufferIndex].mDataByteSize), frames=\(frames), using index \(info.bufferIndex) (\(info))")
            }
            let timestamp = inputTime.pointee
            let hostTime = timestamp.mFlags.contains(.hostTimeValid) ? timestamp.mHostTime : 0
            let sampleTime = timestamp.mFlags.contains(.sampleTimeValid) ? timestamp.mSampleTime : Double.nan
            let chunk = PCMChunk(channels: channels, sampleRate: info.sampleRate, hostTime: hostTime, sampleTime: sampleTime)
            let handler = stateLock.withLock { self.handler }
            handler?(chunk)
        } catch { failCapture(error) }
    }

    /// バッファの不整合を隣の入力へのフォールバックで隠さず、範囲・形式を検証する。
    static func decodeInput(_ inputData: UnsafePointer<AudioBufferList>, info: StreamInfo) throws -> [[Float]] {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let buffers = info.isNonInterleaved ? info.channels : 1
        guard info.isFloat, info.bitsPerChannel == 32, info.channels > 0,
              info.bufferIndex >= 0, info.bufferIndex + buffers <= list.count else {
            throw AudioCaptureError.conversionFailed("音声バッファの形式が一致しません: \(info)")
        }
        var channels: [[Float]] = []
        for index in info.bufferIndex..<(info.bufferIndex + buffers) {
            let buffer = list[index]
            let count = info.isNonInterleaved ? 1 : info.channels
            let bytesPerFrame = MemoryLayout<Float>.size * count
            guard Int(buffer.mNumberChannels) == count, Int(buffer.mDataByteSize) % bytesPerFrame == 0 else {
                throw AudioCaptureError.conversionFailed("音声バッファのチャネル数・バイト数が一致しません")
            }
            let frames = Int(buffer.mDataByteSize) / bytesPerFrame
            // 無音もデータを持つ。NULL/空バッファは停止直後などに発生し得る。
            guard frames > 0, let data = buffer.mData else { return [] }
            let pointer = data.assumingMemoryBound(to: Float.self)
            for channel in 0..<count {
                channels.append((0..<frames).map { pointer[$0 * count + channel] })
            }
        }
        guard channels.allSatisfy({ $0.count == channels.first?.count }) else {
            throw AudioCaptureError.conversionFailed("音声バッファ間のフレーム数が一致しません")
        }
        return channels
    }
}
