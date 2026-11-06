import CoreServices
import Foundation

/// アプリの起動のしかた。`applicationDidFinishLaunching` の中で、起動の Apple イベントから読む（その中でだけ読める）。
/// 確認済み（macOS 26.5 の SDK、AE.framework の AERegistry.h）: ログイン項目で起動すると、kAEOpenApplication の
/// keyAEPropData に keyAELaunchedAsLogInItem（'lgit'）が入る。Dock・Finder・Spotlight からの起動は値なしの 'oapp'、
/// URL を開くための起動は 'GURL' で始まる。
public enum LaunchKind: Equatable, Sendable {
    /// Dock・Finder・Spotlight などから利用者が開いた
    case user
    /// システム設定のログイン項目で、ログイン時に開いた
    case loginItem
    /// URL・ファイル・サービスのための起動（窓はその処理に任せる）
    case other

    public init(event: NSAppleEventDescriptor?) {
        // Apple イベントなし（実行ファイルを直接起動したなど）は、利用者が開いたものとして扱う
        guard let event else {
            self = .user
            return
        }
        guard event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else {
            self = .other
            return
        }
        switch event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue {
        case keyAELaunchedAsLogInItem?: self = .loginItem
        case keyAELaunchedAsServiceItem?: self = .other
        default: self = .user
        }
    }
}

/// 起動したときに出す窓（SPEC §10）。
public enum LaunchWindow: Equatable, Sendable {
    case main, onboarding

    /// 利用者が開いたらメインウィンドウを出し、ログイン時はメニューバーに常駐するだけにする。
    /// 初回の案内を終えていなければ、起動のしかたによらず案内を出す。データベースを開けないときは、
    /// その知らせを出すメインウィンドウを出す（ログイン時でも、使えないまま黙って常駐しない）。
    public static func choose(kind: LaunchKind, needsOnboarding: Bool, startupFailed: Bool) -> LaunchWindow? {
        if startupFailed { return .main }
        if needsOnboarding { return .onboarding }
        return kind == .user ? .main : nil
    }
}
