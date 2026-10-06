import AVFoundation
import Foundation

public struct CaptureFailure: Error, LocalizedError, Sendable, Equatable, Codable {
    public var track: String
    public var operation: String
    public var message: String
    public var errorDescription: String? { "\(track) の\(operation)に失敗しました: \(message)" }
}

/// TrackPipeline のシリアルキュー内だけで使う。テストではディスク書き込み失敗を注入できる。
public protocol TrackFileWriting: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
    func close()
}

public final class TrackFileWriter: TrackFileWriting {
    private let file: AVAudioFile
    public init(url: URL, settings: [String: Any]) throws {
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
    public func write(from buffer: AVAudioPCMBuffer) throws { try file.write(from: buffer) }
    public func close() { file.close() }
}
