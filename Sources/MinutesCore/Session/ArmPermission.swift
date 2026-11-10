import AVFoundation
import Foundation

/// 自動の録音準備を始めなかった、許可の理由（SPEC §6.4）。録音準備は利用者のいないときにも始まる。そこで許可を尋ねると、
/// 答えるまで戻らず、そのあいだ手動の開始もほかの録音準備も始められない。録音準備では尋ねずにやめ、許可を求めるのは
/// 手動の開始と初回の案内にする。会議アプリの音（システムオーディオ録音）の許可は、事前に調べる API がないので見ない
/// （許可がなくても tap は待たずに作れ、無音を録る）。
public enum ArmPermissionError: Error, LocalizedError, Equatable, Sendable {
    /// マイクの許可をまだ尋ねていない（初回の案内で許可を飛ばした、署名の違う版に替えて許可が消えたなど）。
    case microphoneNotDetermined
    /// マイクの許可が断られている・制限されている。
    case microphoneDenied

    /// マイクの許可の状態から、録音準備をやめる理由を返す（許可されていれば nil）。
    public init?(microphone status: AVAuthorizationStatus) {
        switch status {
        case .authorized: return nil
        case .notDetermined: self = .microphoneNotDetermined
        default: self = .microphoneDenied
        }
    }

    public var errorDescription: String? {
        switch self {
        case .microphoneNotDetermined: "マイクの許可がまだないため、録音準備をしません（録音準備では許可を求めません）"
        case .microphoneDenied: "マイクの許可がないため、録音準備をしません"
        }
    }
}
