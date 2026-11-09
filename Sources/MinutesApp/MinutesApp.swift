import AppKit
import MinutesCore
import SwiftUI

@main
struct MinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        // 起動したときに開くかは AppDelegate が決める（利用者が開いたら開き、ログイン時は開かない）。
        // 復元は止めない（止めると窓の位置と大きさも覚えなくなる）
        Window("Minutes", id: AppModel.AppWindow.main.rawValue) {
            MainWindow()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            UpdateCommands(updates: model.updates)
            ImportCommands(model: model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        // 初回の案内。最初の起動で AppDelegate が開く。前回開いていても起動時に復元しない
        Window("Minutes へようこそ", id: AppModel.AppWindow.onboarding.rawValue) {
            OnboardingView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// 起動と、起動中にもう一度開いたとき（Dock・Finder・Spotlight）の窓を決める。アプリ全体の状態（AppModel）もここで持つ。
/// 起動の Apple イベント（ログイン項目かどうか）は applicationDidFinishLaunching の中でしか読めない。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.didFinishLaunching(LaunchKind(event: NSAppleEventManager.shared().currentAppleEvent))
    }

    /// 窓を出していないとき（メニューバー常駐）も届く。AppKit・SwiftUI の既定の動き（最初の Scene を出す）は使わない。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reopen()
        return false
    }
}

/// メニューバーのアイコン。録音中は経過時間を添えて、録り忘れ・止め忘れに気づけるようにする。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let state = model.sessionState
        Group {
            if state == .recording || state == .finalizing {
                HStack(spacing: 4) {
                    Image(systemName: state.symbol)
                    Text(TimeFormatting.mmssShort(model.menuBarElapsedSeconds))
                        .monospacedDigit()
                }
            } else if state == .idle || state == .done {
                Image(nsImage: BrandAssets.menuBarMark)
                    .accessibilityLabel("Minutes — \(state.title)")
            } else {
                Image(systemName: state.symbol)
            }
        }
        // 起動・開き直し・通知のクリックで窓を開く手段。メニューバーのラベルは起動直後から存在する。
        .onAppear {
            model.setWindowOpener { openWindow(id: $0.rawValue) }
        }
    }
}

/// 「ファイル > 音声ファイルを取り込む…」（SPEC §4.4）。メニューはメインウィンドウを出している間だけ現れる。
struct ImportCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("音声ファイルを取り込む…") {
                model.showMainWindow()
                model.showingImportPicker = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

/// アプリのメニューの「アップデートを確認…」（「Minutes について」の下、Mac のアプリの慣例の位置）。メニューバーのパネルの
/// 設定のメニューと同じく、自動更新を使うビルドだけに出し、見つけた新しい版があればその版を入れる操作にする。
struct UpdateCommands: Commands {
    let updates: UpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updates.isAvailable {
                Button(updates.pendingVersion.map { "新しい版（\($0)）を入れる…" } ?? "アップデートを確認…") {
                    updates.checkForUpdates()
                }
            }
        }
    }
}
