import AppKit
import MinutesCore
import SwiftUI

@main
struct MinutesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Minutes", id: "main") {
            MainWindow()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1240, height: 780)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)

        // 初回の案内。最初の起動でメニューバーのラベルから開く（`MenuBarLabel`）。前回開いていても起動時に復元しない
        Window("Minutes へようこそ", id: "onboarding") {
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
        // 通知のクリックでウィンドウを開く手段。メニューバーのラベルは起動直後から存在する。
        .onAppear {
            model.setNotificationWindowOpener {
                openWindow(id: "main")
                model.setMainWindowVisible(true)
            }
            if model.needsOnboarding, !model.presentedOnboarding {
                model.presentedOnboarding = true
                openWindow(id: "onboarding")
            }
        }
    }
}
