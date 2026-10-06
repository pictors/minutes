import Foundation

/// 直近チャンクの音量（dBFS）。統計・ログを伴わない軽量な読み取り用。
public struct TrackLevels: Sendable, Equatable {
    public var systemDb: Float = -120
    public var micDb: Float = -120

    public init(systemDb: Float = -120, micDb: Float = -120) {
        self.systemDb = systemDb
        self.micDb = micDb
    }
}

/// デバイス依存の録音をセッション制御から分離する。
public protocol MeetingRecording: AnyObject, Sendable {
    var options: RecordingOptions { get }
    var startedAt: Date? { get }
    var tappedProcesses: [AudioProcessInfo] { get }
    var systemChunks: AsyncStream<AudioChunk>? { get }
    var micChunks: AsyncStream<AudioChunk>? { get }
    var onEvent: (@Sendable (String) -> Void)? { get set }
    var onFailure: (@Sendable (CaptureFailure) -> Void)? { get set }
    func start() async throws
    func snapshot() -> RecordingSession.Snapshot
    /// 画面のメーター用。`snapshot()` と違い CPU サンプル・診断ログ・区間ピークのリセットを伴わない。
    func levels() -> TrackLevels
    /// 音声が届いていないトラック（"system" / "mic"）。片方が途切れても録音は続ける（SPEC §4.3）。画面の警告用。
    func interruptedTracks() -> [String]
    /// 録音を表示している画面を診断ログに残す（G7）。
    func setUIState(_ state: String?)
    func finishRecording() throws
}

public extension MeetingRecording {
    func levels() -> TrackLevels { TrackLevels() }
    func interruptedTracks() -> [String] { [] }
    func setUIState(_ state: String?) {}
}

extension RecordingSession: MeetingRecording {
    public func finishRecording() throws { _ = try stop() }
}
