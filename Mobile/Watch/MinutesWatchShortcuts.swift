import AppIntents

/// Siri とショートカットの「録音を始める」（SPEC §5.7）。ショートカットの App にも出て、Ultra のアクションボタンにも割り当てられる。
/// アプリ名を含まない言い方は Siri が受け付けない（`\(.applicationName)` を 1 つ入れる決まり）。開発の言語は日本語（project の developmentRegion）。
/// 確認済み（Xcode 27.2 の watchOS 27.2 SDK の AppIntents の swiftinterface）: `AppShortcutsProvider.appShortcuts`（`@AppShortcutsBuilder`）、
/// `AppShortcut(intent:phrases:shortTitle:systemImageName:)`（watchOS 10 から、shortTitle と systemImageName を渡す形）。
struct MinutesWatchShortcuts: AppShortcutsProvider {
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
