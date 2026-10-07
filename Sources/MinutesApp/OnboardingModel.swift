import AppKit
import AVFoundation
import EventKit
import MinutesCore
import UniformTypeIdentifiers
import UserNotifications

/// 初回の案内（2026-10-05 決定。ようこそ → 許可 → 会議アプリ → 文字起こしと要約 → 試しの録音 → 準備完了）。
/// 選んだ内容は段階を進めるときに設定へ保存する（途中でやめても、選んだところまでは残る）。
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable, Comparable {
        case welcome, permissions, apps, providers, test, done

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .welcome: "ようこそ"
            case .permissions: "許可"
            case .apps: "会議アプリ"
            case .providers: "文字起こしと要約"
            case .test: "試しの録音"
            case .done: "準備完了"
            }
        }
    }

    enum CheckState: Equatable {
        case unknown, checking
        case ok(String?)
        case failed(String)

        var isOK: Bool { if case .ok = self { true } else { false } }
    }

    /// 予定の時刻に会議の音を検知したときの動き。
    enum AutoRecord: String, CaseIterable, Identifiable {
        /// 通知とボタンで確かめてから録音する（新しく入れた人の既定、2026-10-05 決定）
        case confirm
        case automatic
        case manual

        var id: String { rawValue }
    }

    enum FullTest: Equatable {
        case idle
        case recording(Int)
        case processing
        case done(meetingId: String)
        case failed(String)
    }

    struct AppChoice: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// 会議に使われるブラウザ。Process Tap はタブ単位で切り出せないので、会議用に 1 つだけ選ぶ（専用ブラウザの運用）。
    static let knownBrowsers: [(bundleID: String, name: String)] = [
        ("com.google.Chrome", "Google Chrome"), ("company.thebrowser.Browser", "Arc"), ("com.microsoft.edgemac", "Microsoft Edge"),
        ("com.brave.Browser", "Brave"), ("org.mozilla.firefox", "Firefox"), ("com.apple.Safari", "Safari"),
        ("com.vivaldi.Vivaldi", "Vivaldi"), ("com.operasoftware.Opera", "Opera"),
    ]
    /// 会議アプリ（アプリの音はそのまま会議の音）。最初の 3 つは、入っていれば初めから選んでおく。
    static let knownMeetingApps: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Microsoft Teams"), ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
    ]
    private static let preselectedMeetingApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams2", "com.cisco.webexmeetingsapp"]

    let model: AppModel
    var step: Step = .welcome
    /// 初めての案内か（会議がまだない環境）。もう一度開いたときは今の設定から始める。
    let isFirstRun: Bool

    private(set) var microphone: AVAuthorizationStatus = .notDetermined
    private(set) var calendar: EKAuthorizationStatus = .notDetermined
    private(set) var notifications: UNAuthorizationStatus = .notDetermined
    private(set) var systemAudio: CheckState = .unknown

    let browsers: [AppChoice]
    let meetingApps: [AppChoice]
    var browser: String?
    var apps: Set<String>
    private(set) var otherApps: [AppChoice]
    var autoRecord: AutoRecord
    private(set) var appsError: String?

    var finalProvider: String
    var summaryProvider: SummaryProvider {
        didSet { summaryTouched = true }
    }
    private(set) var codex: CheckState = .unknown
    private(set) var claudeCode: CheckState = .unknown
    @ObservationIgnored private var summaryTouched = false
    /// 自動録音の選び方を設定へ書いた（会議アプリの段階を通った）。
    @ObservationIgnored private var appliedAutoRecord = false
    private(set) var speechModel: CheckState = .unknown
    private(set) var speechProgress: Double = 0

    let test = TestRecording()
    private(set) var fullTest: FullTest = .idle

    var notice: String

    init(model: AppModel) {
        self.model = model
        let settings = model.settings
        isFirstRun = settings.onboardingCompletedAt == nil
        let installedBrowsers = Self.knownBrowsers.filter { AppNames.url(for: $0.bundleID) != nil }
            .map { AppChoice(bundleID: $0.bundleID, name: AppNames.name(for: $0.bundleID) ?? $0.name) }
        let installedApps = Self.knownMeetingApps.filter { AppNames.url(for: $0.bundleID) != nil }
            .map { AppChoice(bundleID: $0.bundleID, name: AppNames.name(for: $0.bundleID) ?? $0.name) }
        browsers = installedBrowsers
        meetingApps = installedApps
        let targets = settings.targetBundleIdentifiers
        browser = targets.first { id in installedBrowsers.contains { $0.bundleID == id } }
        var selected = Set(targets.filter { id in installedApps.contains { $0.bundleID == id } })
        if isFirstRun {
            selected.formUnion(installedApps.map(\.bundleID).filter(Self.preselectedMeetingApps.contains))
        }
        apps = selected
        let known = Set(Self.knownBrowsers.map(\.bundleID) + Self.knownMeetingApps.map(\.bundleID))
        otherApps = targets.filter { !known.contains($0) }.map { AppChoice(bundleID: $0, name: AppNames.name(for: $0) ?? $0) }
        autoRecord = isFirstRun ? .confirm : (settings.autoStartOnAudio ? (settings.confirmBeforeAutoStart ? .confirm : .automatic) : .manual)
        // 初めての人は、キーのあるクラウドか、なければこの Mac の中で文字起こしするところから始める
        let keyReady: (String) -> Bool = { id in ProviderCatalog.final(id)?.keyName.map { KeyStatus.resolve($0).isAvailable } ?? true }
        finalProvider = !isFirstRun || keyReady(settings.finalProviderId) ? settings.finalProviderId
            : (keyReady("elevenlabs.scribe_v2") ? "elevenlabs.scribe_v2" : "local.speechanalyzer+fluidaudio")
        summaryProvider = settings.resolvedSummaryProvider
        notice = settings.resolvedRecordingNotice
        summaryTouched = false
    }

    // MARK: - 進む・戻る

    func next() {
        switch step {
        case .apps:
            guard applyApps() else { return }
        case .providers:
            applyProviders()
        case .test:
            test.cancel()
        default:
            break
        }
        if let next = Step(rawValue: step.rawValue + 1) { step = next }
    }

    func back() {
        if step == .test { test.cancel() }
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    /// 最後まで進めずに閉じた（「あとで設定する」・閉じるボタン）。会議アプリの段階まで進んでいなければ、
    /// 自動録音は新しく入れた人の既定（確認してから録音）にする。
    func skip() {
        test.cancel()
        guard model.needsOnboarding else { return }
        if !appliedAutoRecord {
            var settings = model.settings
            applyAutoRecord(to: &settings)
            model.updateSettings(settings)
        }
        model.completeOnboarding()
    }

    func complete() {
        test.cancel()
        var settings = model.settings
        let trimmed = notice.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.recordingNotice = trimmed.isEmpty || trimmed == AppSettings.defaultRecordingNotice ? nil : trimmed
        model.updateSettings(settings)
        model.completeOnboarding()
    }

    // MARK: - 許可

    func refreshPermissions() async {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        calendar = EKEventStore.authorizationStatus(for: .event)
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestMicrophone() async {
        _ = await MicCapture.requestPermission()
        await refreshPermissions()
    }

    func requestCalendar() async {
        _ = await model.calendar.requestAccess()
        await refreshPermissions()
        model.refreshCandidates()
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refreshPermissions()
    }

    /// テスト音を Minutes 自身が鳴らして録れるかを見る（事前に調べる API がない）。
    func checkSystemAudio() async {
        systemAudio = .checking
        let stamp = JSONCoding.iso8601Local(Date())
        switch await SystemAudioCheck.run() {
        case .granted:
            systemAudio = .ok(nil)
            model.lastSystemAudioCheck = "許可（\(stamp) のテスト音）"
        case .silent:
            systemAudio = .failed("テスト音を録音できませんでした。許可を求められたら「許可」を押してから、もう一度確かめてください。")
            model.lastSystemAudioCheck = "テスト音が届かない（\(stamp)）"
        case let .failed(message):
            systemAudio = .failed(message)
            model.lastSystemAudioCheck = "確かめられない（\(stamp)）"
        }
    }

    // MARK: - 会議アプリ

    var targetBundleIdentifiers: [String] {
        var result: [String] = []
        for id in [browser].compactMap({ $0 }) + meetingApps.map(\.bundleID).filter(apps.contains) + otherApps.map(\.bundleID)
            where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    func addOtherApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.message = "会議に使うアプリを選んでください"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier, !targetBundleIdentifiers.contains(id) else { continue }
            otherApps.append(AppChoice(bundleID: id, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
        }
    }

    func removeOtherApp(_ id: String) {
        otherApps.removeAll { $0.bundleID == id }
    }

    @discardableResult
    func applyApps() -> Bool {
        let targets = targetBundleIdentifiers
        guard !targets.isEmpty else {
            appsError = "録音するアプリを 1 つ以上選んでください。"
            return false
        }
        appsError = nil
        var settings = model.settings
        settings.targetBundleIdentifiers = targets
        applyAutoRecord(to: &settings)
        model.updateSettings(settings)
        return true
    }

    private func applyAutoRecord(to settings: inout AppSettings) {
        switch autoRecord {
        case .confirm:
            settings.autoStartOnAudio = true
            settings.confirmBeforeAutoStart = true
        case .automatic:
            settings.autoStartOnAudio = true
            settings.confirmBeforeAutoStart = false
        case .manual:
            settings.autoStartOnAudio = false
        }
        appliedAutoRecord = true
    }

    // MARK: - 文字起こしと要約

    /// Codex と Claude Code にログインしているかを確かめる（推論・会議データの送信はしない）。
    /// 初めての案内では、確かめた結果から要約の手段を選んでおく（Codex → Claude Code → Anthropic → 要約しない）。
    func checkSummaryConnections() async {
        // 段階を行き来するたびにプロセスを起動しない
        if codex.isOK && claudeCode.isOK { return }
        if codex == .checking || claudeCode == .checking { return }
        codex = .checking
        claudeCode = .checking
        let settings = model.settings
        async let codexResult = Self.checkCodex(path: settings.codexExecutablePath)
        async let claudeResult = Self.checkClaudeCode(path: settings.claudeCodeExecutablePath)
        codex = await codexResult
        claudeCode = await claudeResult
        guard isFirstRun, !summaryTouched else { return }
        let choice: SummaryProvider = if codex.isOK {
            .codex
        } else if claudeCode.isOK {
            .claudeCode
        } else if KeyStatus.resolve(APIKeys.anthropic).isAvailable {
            .anthropic
        } else {
            .none
        }
        summaryProvider = choice
        summaryTouched = false
    }

    private static func checkCodex(path: String?) async -> CheckState {
        do {
            let connection = try await CodexSummarizer(executablePath: path, timeoutSeconds: 20).checkConnection()
            return .ok(connection.account)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func checkClaudeCode(path: String?) async -> CheckState {
        do {
            let connection = try await ClaudeCodeSummarizer(executablePath: path, timeoutSeconds: 20).checkConnection()
            return .ok(connection.label)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// ライブ字幕の日本語モデルを先に入れる（初めての録音で待たせない）。
    func prepareSpeechModel() async {
        if case .checking = speechModel { return }
        if speechModel.isOK { return }
        speechModel = .checking
        do {
            try await SpeechAssets.prepareLiveTranscription(locale: model.settings.meetingLanguage.liveLanguage.locale) { [weak self] fraction in
                Task { @MainActor in self?.speechProgress = fraction }
            }
            speechProgress = 1
            speechModel = .ok(nil)
        } catch {
            speechModel = .failed(error.localizedDescription)
        }
    }

    func applyProviders() {
        var settings = model.settings
        settings.finalProviderId = finalProvider
        settings.summaryProvider = summaryProvider
        model.updateSettings(settings)
    }

    // MARK: - 試しの録音

    func startTest() async {
        applyApps()
        applyProviders()
        await test.start(settings: model.settings)
    }

    /// 20 秒を会議として録音し、文字起こしと要約まで流す（任意。2026-10-05 決定）。
    func runFullTest() async {
        test.cancel()
        applyApps()
        applyProviders()
        model.operationError = nil
        model.startRecording(PendingMeetingInfo(title: "試しの録音"))
        var meetingId: String?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            // 始められなかった理由はこの画面に出す（メニューバーのパネルやウィンドウに残さない）
            if let error = model.operationError {
                model.operationError = nil
                fullTest = .failed(error)
                return
            }
            if model.sessionState == .recording, let id = model.currentMeeting?.id {
                meetingId = id
                break
            }
        }
        guard let meetingId else {
            fullTest = .failed("録音を始められませんでした。")
            return
        }
        for remaining in stride(from: TestRecording.duration, to: 0, by: -1) {
            fullTest = .recording(remaining)
            try? await Task.sleep(for: .seconds(1))
        }
        model.stopRecording()
        fullTest = .processing
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
            guard let meeting = try? model.store?.meeting(id: meetingId) else { continue }
            switch meeting.meetingStatus {
            case .done:
                fullTest = .done(meetingId: meetingId)
                return
            case .failed:
                fullTest = .failed("議事録を作れませんでした。会議の画面で理由を確かめられます。")
                return
            default:
                continue
            }
        }
        fullTest = .failed("5 分たっても議事録ができませんでした。会議の画面で進み具合を確かめられます。")
    }
}
