import AppKit
import AVFoundation
import Darwin
import EventKit
import MinutesCore
import UniformTypeIdentifiers
import UserNotifications

/// 診断情報の書き出し（設定 > 診断）。アプリが知っている環境（版・OS・許可・プロバイダの状態）を集めて MinutesCore の
/// `DiagnosticsReport` に渡す。本文・音声・API キーは入れず、会議名は会議の ID に置き換える（2026-10-05 決定）。
extension AppModel {
    func diagnosticsReport() async throws -> DiagnosticsReport {
        guard let store else { throw CocoaError(.fileReadUnknown) }
        let bundle = Bundle.main
        let app = [
            "bundle_id": bundle.bundleIdentifier ?? "-",
            "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
        ]
        let process = ProcessInfo.processInfo
        let system = [
            "macos": process.operatingSystemVersionString,
            "model": Self.hardwareModel() ?? "-",
            "memory_gb": String(Int((Double(process.physicalMemory) / 1_073_741_824).rounded())),
            "processors": String(process.activeProcessorCount),
            "locale": Locale.current.identifier,
        ]
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        let permissions = [
            "microphone": Self.describe(AVCaptureDevice.authorizationStatus(for: .audio)),
            "calendar": Self.describe(EKEventStore.authorizationStatus(for: .event)),
            "notifications": Self.describe(notifications),
            // 事前に調べる API がないので、初回の案内のテスト音で確かめた結果だけを残す
            "system_audio": lastSystemAudioCheck ?? "未確認",
        ]
        var providers = [
            "final": settings.finalProviderId,
            "final_ready": String(finalProviderReady),
            "summary": settings.resolvedSummaryProvider.rawValue,
        ]
        for (label, name) in [("key_elevenlabs", APIKeys.elevenLabs), ("key_openai", APIKeys.openAI), ("key_anthropic", APIKeys.anthropic)] {
            providers[label] = switch KeyStatus.resolve(name) {
            case .keychain: "Keychain"
            case .environment: ".env / 環境変数"
            case .missing: "なし"
            }
        }
        providers["codex_cli"] = SummaryCLI.codex.executable(configuredPath: settings.codexExecutablePath).map { Self.homeRedacted($0.path) } ?? "見つからない"
        providers["claude_cli"] = SummaryCLI.claudeCode.executable(configuredPath: settings.claudeCodeExecutablePath).map { Self.homeRedacted($0.path) } ?? "見つからない"
        providers["speech_installed_locales"] = await SpeechAssets.installedLocales().map(\.identifier).sorted().joined(separator: ", ")
        let session = [
            "state": sessionState.title,
            "post_processing": postProcessingSummary ?? "なし",
        ]
        let environment = DiagnosticsReport.Environment(app: app, system: system, permissions: permissions, providers: providers, session: session)
        return try DiagnosticsReport.collect(store: store, settings: settings, events: events, environment: environment)
    }

    /// 保存先を選ばせて書き出す。書き出したファイル名を返す（取り消しなら nil）。
    func exportDiagnostics() async throws -> String? {
        let data = try JSONCoding.encoder().encode(try await diagnosticsReport())
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Minutes 診断情報 \(JSONCoding.folderTimestamp(Date())).json"
        panel.message = "本文・音声・API キーは入りません。会議名は会議の ID に置き換えています。"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url.lastPathComponent
    }

    private static func hardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// ホームフォルダ（利用者の名前が入る）を「~」にする。
    private static func homeRedacted(_ path: String) -> String {
        let home = NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "許可"
        case .denied: "拒否"
        case .restricted: "制限"
        case .notDetermined: "未確認"
        @unknown default: "不明"
        }
    }

    private static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .fullAccess: "許可"
        case .writeOnly: "書き込みのみ"
        case .denied: "拒否"
        case .restricted: "制限"
        case .notDetermined: "未確認"
        @unknown default: "不明"
        }
    }

    private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: "許可"
        case .denied: "拒否"
        case .notDetermined: "未確認"
        @unknown default: "不明"
        }
    }
}
