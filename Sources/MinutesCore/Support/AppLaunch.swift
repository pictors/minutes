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

/// 終了の求め。`applicationShouldTerminate` の中で、終了の Apple イベントから読む（SPEC §6.4）。
/// 確認済み（macOS 26.5 の SDK、AE.framework の AERegistry.h）: ログアウト・再起動・システム終了で届く kAEQuitApplication には、
/// 理由（kAEQuitReason、'why?'）として kAEQuitAll・kAEShutDown・kAERestart・kAEReallyLogOut が入る。⌘Q とメニューの終了は
/// Apple イベントなし、Dock の「終了」とほかのアプリからの終了（Sparkle の更新は `NSRunningApplication.terminate()`、
/// Sparkle 2.10.0 の InstallerProgressAppController.m で確認）は理由なしの 'quit'。
public enum QuitRequest: Equatable, Sendable {
    /// 利用者の終了（⌘Q・メニュー・Dock）と、ほかのアプリからの終了（更新など）。録音中なら止めてよいか確かめる
    case user
    /// ログアウト・再起動・システム終了。確かめずに録音を止めて保存する（確認の窓を出しても、待ってもらえない）
    case system

    static let systemReasons: Set<OSType> = [
        OSType(kAEQuitAll), OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut),
        OSType(kAELogOut), OSType(kAEShowRestartDialog), OSType(kAEShowShutdownDialog),
    ]

    public init(event: NSAppleEventDescriptor?) {
        guard let event, event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication else {
            self = .user
            return
        }
        // 属性として届く（パラメータとして届いても読む）
        let keyword = AEKeyword(kAEQuitReason)
        let reason = event.attributeDescriptor(forKeyword: keyword) ?? event.paramDescriptor(forKeyword: keyword)
        let code = reason.map { $0.enumCodeValue != 0 ? $0.enumCodeValue : $0.typeCodeValue } ?? 0
        self = Self.systemReasons.contains(code) ? .system : .user
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
