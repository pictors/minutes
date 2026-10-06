import CoreAudio

/// 入出力が別の AudioDevice になる Bluetooth 機器も、接続種別で判別する。
/// Core Audio の transportType / isAlive は AudioHardwareClock のプロパティ
/// （Apple の API リファレンスと macOS 26 SDK を確認、2026-09-28）。
enum AudioClockDeviceSelection {
    struct Candidate {
        var id: AudioObjectID
        var transportType: UInt32
        var inputStreams: Int
        var outputStreams: Int
        var isAlive: Bool = true
    }

    static func select(from candidates: [Candidate], defaultOutputID: AudioObjectID?) -> AudioObjectID? {
        candidates.filter { $0.isAlive && $0.outputStreams > 0 }.min {
            priority($0, defaultOutputID: defaultOutputID) < priority($1, defaultOutputID: defaultOutputID)
        }?.id
    }

    private static func priority(_ device: Candidate, defaultOutputID: AudioObjectID?) -> (Int, Int, Int, UInt32) {
        let transport: Int
        switch device.transportType {
        case kAudioDeviceTransportTypeBuiltIn: transport = 0
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: transport = 1
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
             kAudioDeviceTransportTypeAirPlay: transport = 3
        default: transport = 2
        }
        return (transport, device.inputStreams == 0 ? 0 : 1, device.id == defaultOutputID ? 0 : 1, device.id)
    }
}
