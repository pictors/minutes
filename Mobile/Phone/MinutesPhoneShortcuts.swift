import AppIntents

/// Siri・Spotlight・ショートカットの「録音を始める」（SPEC §5.7）。ショートカットの App にも出て、アクションボタンにも割り当てられる。
/// 言い方は Watch（`MinutesWatchShortcuts`）と同じ。アプリ名を含まない言い方は Siri が受け付けない（`\(.applicationName)` を 1 つ入れる決まり）。
/// 開発の言語は日本語（project の developmentRegion）。App Shortcuts の提供元はアプリに 1 つだけ置く（拡張には入れない）。
/// 確認済み（Xcode 27.2 の iOS 27.2 SDK の AppIntents の swiftinterface）: `AppShortcutsProvider.appShortcuts`（`@AppShortcutsBuilder`）、
/// `AppShortcut(intent:phrases:shortTitle:systemImageName:)`（iOS 17 から、shortTitle と systemImageName を渡す形）、
/// `AppShortcutPhraseToken.applicationName`。シミュレータ（iOS 26.5）の Spotlight で「Minutes」を探すと、アプリの隣に「録音を始める」が出た。
struct MinutesPhoneShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "\(.applicationName)で録音",
                "\(.applicationName)で録音を始める",
                "\(.applicationName)で録音して",
            ],
            shortTitle: "録音を始める",
            systemImageName: "record.circle.fill"
        )
    }
}
