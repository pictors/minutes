import AppKit
import Foundation
import EventKit
import GRDB
import MinutesCore
import Observation
import SwiftUI
import UserNotifications

/// ライブ字幕の確定行。
struct LiveLine: Identifiable, Sendable {
    var id = UUID()
    var track: String
    var start: Double
    var text: String
}

enum SmartFolder: String, CaseIterable, Identifiable, Sendable {
    case today, thisWeek, all, unprocessed, failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今日"
        case .thisWeek: return "今週"
        case .all: return "すべて"
        case .unprocessed: return "処理中"
        case .failed: return "失敗"
        }
    }

    var systemImage: String {
        switch self {
        case .today: return "sun.max"
        case .thisWeek: return "calendar"
        case .all: return "tray.full"
        case .unprocessed: return "hourglass"
        case .failed: return "exclamationmark.triangle"
        }
    }

    var filter: MeetingFilter {
        switch self {
        case .today: return .today
        case .thisWeek: return .thisWeek
        case .all: return .all
        case .unprocessed: return .processing
        case .failed: return .status(.failed)
        }
    }
}

/// サイドバーの選択（スマートフォルダ or タグ）。
enum SidebarItem: Hashable, Sendable {
    case folder(SmartFolder)
    case tag(String)

    var title: String {
        switch self {
        case let .folder(folder): return folder.title
        case let .tag(tag): return tag
        }
    }

    var systemImage: String {
        switch self {
        case let .folder(folder): return folder.systemImage
        case .tag: return "tag"
        }
    }

    var filter: MeetingFilter {
        switch self {
        case let .folder(folder): return folder.filter
        case let .tag(tag): return .tag(tag)
        }
    }

    var folder: SmartFolder? {
        if case let .folder(folder) = self { return folder }
        return nil
    }
}

/// アプリ全体の状態（メニューバー・ウィンドウ・設定が共有する）。
@MainActor
@Observable
final class AppModel {
    nonisolated static let startRecordingActionIdentifier = "jp.pictors.minutes.action.start-recording"
    nonisolated static let confirmStartCategoryIdentifier = "jp.pictors.minutes.category.confirm-start"

    private(set) var settings: AppSettings
    private(set) var store: Store?
    private(set) var pipeline: PostProcessPipeline?
    private(set) var session: MeetingSessionController?
    private(set) var postProcessingQueue: PostProcessingQueue?
    private(set) var postProcessingJobs: [PostProcessingJob] = []
    let calendar = CalendarService()
    let detector = MeetingDetector()
    let playback = AudioPlayback()
    /// 自動更新（配布用のビルドだけ）
    let updates = UpdateController()

    private(set) var sessionState: SessionState = .idle
    private(set) var currentMeeting: MeetingRecord?
    private(set) var liveVolatile: [String: String] = [:]
    private(set) var liveLines: [LiveLine] = []
    /// 画面に出す前の途中経過（`scheduleVolatileFlush` でまとめて liveVolatile に移す）。
    @ObservationIgnored private var pendingVolatile: [String: String] = [:]
    @ObservationIgnored private var volatileFlush: Task<Void, Never>?
    private(set) var events: [String] = []
    private(set) var candidates: [CalendarCandidate] = []
    private(set) var meetings: [MeetingRecord] = []
    /// meeting id → 要約 1 行目（一覧の副題）。
    private(set) var meetingPreviews: [String: String] = [:]
    /// メニューバーの「最近の会議」。選択中のフォルダに依存しない。
    private(set) var recentMeetings: [MeetingRecord] = []
    /// メニューバーの「概要」（今日・週ごとの会議時間）: 直近 `panelWeeks` 週 + 比較用の 1 週に開始した会議。
    private(set) var panelMeetings: [MeetingRecord] = []
    /// パネルで遡れる週の数（今週を含む）。
    static let panelWeeks = 8
    @ObservationIgnored private var panelMeetingsSince: Date?
    /// 全会議のタグと件数（サイドバー）。
    private(set) var tags: [TagCount] = []
    var selectedItem: SidebarItem = .folder(.thisWeek)
    var selectedMeetingId: String?
    var searchText = ""
    private(set) var searchResults: [SearchResult] = []
    private(set) var isSearching = false
    var isSearchActive: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    private(set) var startupError: String?
    var operationError: String?
    @ObservationIgnored private var notesDrafts: [String: UserNotesDraft] = [:]
    var privacyModeForNextMeeting: PrivacyMode
    /// minutes://meeting/<id>?seg=<n> で指定されたセグメント
    var pendingSegmentId: Int64?
    /// 表示中の会議の「⋯」（ウィンドウのツールバー）の状態。会議を出していなければ nil。
    /// 等しい値の代入は通知されないので、状態が同じ会議どうしの切り替えではツールバーを作り直さない。
    var meetingActions: MeetingActionsState?
    /// 「⋯」の操作の対象。押したときに読むだけなので監視しない（切り替えのたびにツールバーを更新させない）。
    @ObservationIgnored var meetingActionsTarget: MeetingActionsTarget?
    /// minutes://settings?tab=<tab> やサイドバーから要求された設定タブ。設定画面が開いたら消費する。
    var requestedSettingsTab: SettingsTab?
    /// Keychain の API キーを保存・削除するたびに増える（キーの有無で変わる表示の更新用）。
    private(set) var apiKeysRevision = 0
    /// armed 中に音声を検知し、設定により開始の確認を待っている。
    private(set) var awaitingStartConfirmation = false
    /// 録音中の経過時間。表示する場所ごとに分け、見えていない場所は更新しない。閉じたパネルやウィンドウも、値が替わるたびに
    /// レイアウトをやり直すため（G7）。メニューバーは常に見えている。パネルとウィンドウは見え始めたらすぐ最新にする。
    private(set) var menuBarElapsedSeconds: Double = 0
    private(set) var panelElapsedSeconds: Double = 0
    private(set) var windowElapsedSeconds: Double = 0
    @ObservationIgnored private var visibleElapsedSurfaces: Set<ElapsedSurface> = []
    /// 初回の案内のテスト音で確かめた、会議アプリの音の録音の許可（診断情報用。事前に調べる API がない）。
    var lastSystemAudioCheck: String?

    enum ElapsedSurface { case panel, window }
    private var meetingsObservation: Task<Void, Never>?
    private var recentObservation: Task<Void, Never>?
    private var panelObservation: Task<Void, Never>?
    private var tagsObservation: Task<Void, Never>?
    private var jobsObservation: Task<Void, Never>?
    @ObservationIgnored private let hotKeys = GlobalHotKeyCenter()
    /// ショートカットの登録失敗（設定画面に表示）。
    private(set) var shortcutError: String?
    private var sessionGeneration = UUID()
    private var housekeepingTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var rebuildAfterRecording = false
    private var autoStartTask: Task<Void, Never>?
    private var autoStartObservers: [NSObjectProtocol] = []
    /// 自動録音判定の再入防止。UI の「録音中」判定には使わない。
    private var checkingArm = false
    private var startingRecording = false
    @ObservationIgnored private let notificationDelegate = NotificationDelegate()

    init() {
        var settings = AppSettings.load()
        self.privacyModeForNextMeeting = settings.defaultPrivacyMode
        var openedStore: Store?
        var openError: (any Error)?
        do { openedStore = try Store.open() } catch { openError = error }
        // 初回の案内を作る前から使っている人（会議がある）には案内を出さず、設定も変えない
        if settings.onboardingCompletedAt == nil, let openedStore, (try? openedStore.listMeetings(.all, limit: 1).isEmpty) == false {
            settings.onboardingCompletedAt = Date()
            try? settings.save()
        }
        self.settings = settings
        if let openError {
            startupError = "データベースを開けません: \(openError.localizedDescription)"
        }
        if let store = openedStore {
            self.store = store
            rebuildPipeline()
            observeMeetings()
            observeRecentMeetings()
            observePanelMeetings()
            observeTags()
            observePostProcessingJobs()
        }
        applyGlobalShortcut()
        // NSApplication の起動処理が終わってから外観を当てる
        Task { @MainActor [weak self] in self?.applyAppearance() }
        detector.targetBundleIdentifiers = settings.targetBundleIdentifiers
        detector.onTargetTerminated = { [weak self] _ in
            Task { await self?.session?.targetProcessExited() }
        }
        detector.onTargetLaunched = { [weak self] _ in
            Task { await self?.checkArmCondition() }
        }
        detector.start()
        configureNotifications()
        startHousekeeping()
        startAutoRecordingChecks()
        Task {
            // 初回の案内では、許可を案内の中で 1 つずつ求める
            guard !needsOnboarding else { return }
            _ = await calendar.requestAccess()
            await checkArmCondition()
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    // MARK: - 初回の案内

    /// 初回の案内をまだ終えていない。終えるまで自動録音の準備をしない（許可も選んでいないうちに録音を始めない）。
    var needsOnboarding: Bool { settings.onboardingCompletedAt == nil }
    /// この起動で案内を開いた（メニューバーのラベルが出直しても開き直さない）。
    @ObservationIgnored var presentedOnboarding = false

    func completeOnboarding() {
        guard needsOnboarding else { return }
        var updated = settings
        updated.onboardingCompletedAt = Date()
        updateSettings(updated)
    }

    // MARK: - Settings / providers

    func updateSettings(_ newSettings: AppSettings) {
        var sameExceptAppearance = newSettings
        sameExceptAppearance.appearance = settings.appearance
        let appearanceOnly = sameExceptAppearance == settings
        if privacyModeForNextMeeting == settings.defaultPrivacyMode {
            privacyModeForNextMeeting = newSettings.defaultPrivacyMode
        }
        settings = newSettings
        do { try newSettings.save() } catch {
            operationError = "設定を保存できません: \(error.localizedDescription)"
            appendEvent(operationError ?? error.localizedDescription)
        }
        applyAppearance()
        // テーマだけの変更で録音・後処理の構成を作り直さない
        guard !appearanceOnly else { return }
        detector.targetBundleIdentifiers = newSettings.targetBundleIdentifiers
        applyGlobalShortcut()
        rebuildPipeline()
        Task { await checkArmCondition() }
    }

    /// メニューバーのパネルからテーマを切り替える。
    func setAppearance(_ appearance: AppAppearance) {
        guard settings.appearance != appearance else { return }
        var updated = settings
        updated.appearance = appearance
        updateSettings(updated)
    }

    /// テーマを全ウィンドウ（メニューバーのパネル・メインウィンドウ・設定・ポップオーバー）に当てる。
    func applyAppearance() {
        NSApp?.appearance = switch settings.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// 設定のショートカットを Carbon ホットキーとして登録する（nil なら解除）。
    private func applyGlobalShortcut() {
        hotKeys.register(settings.globalShortcut) { [weak self] in self?.toggleRecordingFromShortcut() }
        shortcutError = hotKeys.lastError
    }

    /// ショートカットの動作: 待機中は録音開始、準備中は今すぐ開始、録音中は停止。画面がなくても通知で結果を知らせる。
    func toggleRecordingFromShortcut() {
        switch sessionState {
        case .idle:
            guard !startingRecording else { return }
            startRecording()
            AppModel.postNotification(title: "録音を開始します", body: "ショートカット \(settings.globalShortcut?.display ?? "") で開始しました。もう一度押すと停止します。")
        case .armed:
            startNow()
        case .recording, .finalizing:
            stopRecording()
            AppModel.postNotification(title: "録音を停止しました", body: "文字起こしと要約を作成します。")
        default:
            break
        }
    }

    func rebuildPipeline() {
        guard let store else { return }
        // 設定保存で進行中の録音セッションを差し替えない。
        guard !isRecording else { rebuildAfterRecording = true; return }
        rebuildAfterRecording = false
        let cloud: (any BatchTranscriber)?
        switch settings.finalProviderId {
        case "openai.gpt-4o-transcribe-diarize":
            cloud = APIKeys.resolve(APIKeys.openAI).map { OpenAITranscriber(apiKey: $0) }
        case "local.speechanalyzer+fluidaudio":
            cloud = nil
        default:
            cloud = APIKeys.resolve(APIKeys.elevenLabs).map { ElevenLabsTranscriber(apiKey: $0) }
        }
        let local = LocalTranscriber(locale: Locale(identifier: settings.liveLocale))
        let summarizer = try? SummaryProviders.make(settings: settings)
        var targets: [any SyncTarget] = []
        if let sync = settings.syncDirectoryURL { targets.append(LocalDirectorySyncTarget(destination: sync)) }
        let providers = PipelineProviders(
            cloud: cloud,
            local: local,
            summarizer: summarizer,
            exportDirectory: settings.exportDirectoryURL,
            syncTargets: targets,
            learnKeyterms: settings.keytermsAutoLearn,
            notify: { meeting, notes in
                Task { @MainActor in
                    AppModel.postNotification(title: "議事録ができました", body: meeting.title + (notes?.summaryMd == nil ? "（要約なし）" : ""), meetingId: meeting.id)
                }
            },
            onProgress: { [weak self] _, step, message in
                Task { @MainActor in self?.appendEvent("\(step.rawValue): \(message)") }
            }
        )
        let pipeline = PostProcessPipeline(store: store, providers: providers)
        self.pipeline = pipeline
        let queue: PostProcessingQueue
        if let existing = postProcessingQueue {
            existing.updatePipeline(pipeline)
            queue = existing
        } else {
            queue = PostProcessingQueue(store: store, pipeline: pipeline) { [weak self] event in
                Task { @MainActor in self?.handlePostProcessing(event) }
            }
            postProcessingQueue = queue
        }
        var configuration = SessionConfiguration(targetBundleIdentifiers: settings.targetBundleIdentifiers, audioRootDirectory: settings.audioRootDirectoryURL)
        configuration.includeMic = settings.includeMic
        configuration.micDeviceUID = settings.micDevice
        configuration.liveLocale = Locale(identifier: settings.liveLocale)
        configuration.silenceTimeout = settings.silenceTimeoutSeconds
        configuration.confirmBeforeAutoStart = settings.confirmBeforeAutoStart
        let session = MeetingSessionController(store: store, pipeline: pipeline, configuration: configuration, postProcessingQueue: queue)
        self.session = session
        let generation = UUID()
        sessionGeneration = generation
        Task {
            await session.setHandlers(
                state: { [weak self] state, meeting in
                    Task { @MainActor in
                        guard self?.sessionGeneration == generation else { return }
                        self?.handleState(state, meeting: meeting)
                    }
                },
                live: { [weak self] meetingId, track, segment in
                    Task { @MainActor in
                        guard self?.sessionGeneration == generation else { return }
                        self?.handleLive(meetingId: meetingId, track: track, segment: segment)
                    }
                },
                event: { [weak self] message in
                    Task { @MainActor in self?.appendEvent(message) }
                }
            )
            await session.setConfirmationHandler { [weak self] meeting in
                Task { @MainActor in
                    guard self?.sessionGeneration == generation else { return }
                    self?.handleStartConfirmationRequest(meeting)
                }
            }
            await queue.start()
        }
    }

    var hasCloudTranscriber: Bool { hasKey(APIKeys.elevenLabs) || hasKey(APIKeys.openAI) }
    /// 要約できるか。Codex / Claude Code は実行時まで分からないので可とする。「要約しない」と、キーのない Anthropic は不可。
    var hasSummarizer: Bool {
        switch settings.resolvedSummaryProvider {
        case .codex, .claudeCode: true
        case .anthropic: hasKey(APIKeys.anthropic)
        case .none: false
        }
    }
    var summaryLabel: String {
        switch settings.resolvedSummaryProvider {
        case .codex: "Codex / \(settings.codexModel.flatMap { $0.isEmpty ? nil : $0 } ?? "既定モデル")"
        case .claudeCode: "Claude Code / \(settings.claudeCodeModel.flatMap { $0.isEmpty ? nil : $0 } ?? "既定モデル")"
        case .anthropic: settings.summaryModel
        case .none: "要約しない"
        }
    }
    /// サイドバーの要約の状態。「要約しない」は選んだ結果なので未設定と区別する。
    var summaryStatusLabel: String {
        settings.resolvedSummaryProvider == .none || hasSummarizer ? summaryLabel : "未設定"
    }
    /// サイドバー等に出す確定文字起こしの表示名。クラウドを選んでいてもキーがなければローカルにフォールバックする旨を示す。
    var finalProviderLabel: String {
        finalProviderReady ? ProviderCatalog.finalTitle(settings.finalProviderId) : "ローカル（キー未設定）"
    }
    /// 選択中の確定プロバイダが使えるか（ローカルは常に可、クラウドは対応するキーがあるとき）。
    var finalProviderReady: Bool {
        guard let entry = ProviderCatalog.final(settings.finalProviderId) else { return hasCloudTranscriber }
        guard let key = entry.keyName else { return true }
        return hasKey(key)
    }

    // MARK: - API キー

    /// API キーを Keychain に保存する（前後の空白・改行は除く）。.env より優先し、次の後処理から使う。
    func saveAPIKey(_ value: String, name: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        try KeychainStore.set(key, account: name)
        apiKeysDidChange()
    }

    func deleteAPIKey(name: String) throws {
        try KeychainStore.delete(account: name)
        apiKeysDidChange()
    }

    /// キーがあるか。`apiKeysRevision` を読み、設定でキーを変えたらサイドバーなどの表示を更新させる。
    private func hasKey(_ name: String) -> Bool {
        _ = apiKeysRevision
        return APIKeys.resolve(name) != nil
    }

    private func apiKeysDidChange() {
        apiKeysRevision += 1
        rebuildPipeline()
    }
    /// 自分（mic）の表示名。設定が空なら「自分」。
    var selfDisplayName: String { settings.resolvedSelfName ?? "自分" }

    // MARK: - Session

    /// 録音セッションが動いている（準備中・録音中・終了待ち）。自動録音の判定処理（`checkingArm`）は含めない。
    var isRecording: Bool { startingRecording || sessionState == .recording || sessionState == .finalizing || sessionState == .armed }
    var isArmed: Bool { sessionState == .armed }

    var postProcessingSummary: String? {
        let running = postProcessingJobs.filter { $0.jobStatus == .running }.count
        let queued = postProcessingJobs.filter { $0.jobStatus == .queued }.count
        guard running + queued > 0 else { return nil }
        return "後処理: \(running) 件実行中・\(queued) 件待機"
    }

    /// 手動開始。開始できなければアラートで理由を示す（権限・対象アプリ未起動など）。
    func startRecording(_ info: PendingMeetingInfo? = nil) {
        guard let session, !startingRecording else { return }
        startingRecording = true
        var pending = info ?? PendingMeetingInfo(title: defaultTitle())
        if info == nil { pending.privacyMode = privacyModeForNextMeeting }
        if let eventId = pending.calendarEventId, let candidate = candidates.first(where: { $0.id == eventId }), let store {
            _ = try? store.claimAutoRecording(occurrence: eventId + "/" + Store.isoString(candidate.startDate), expiresAt: candidate.endDate, now: Date())
        }
        liveLines = []
        clearLiveVolatile()
        Task {
            defer {
                startingRecording = false
                if rebuildAfterRecording, !isRecording { rebuildPipeline() }
            }
            do {
                try await session.start(pending)
                // 手動開始は録音ビューを見せる（自動開始では選択を変えない）
                if let meeting = await session.currentMeeting { selectedMeetingId = meeting.id }
            } catch {
                // 画面には分かる言葉で、ログには元の理由を残す
                operationError = "録音を開始できません: " + SetupMessages.describe(error, targets: pending.targetBundleIdentifiers ?? settings.targetBundleIdentifiers)
                appendEvent("録音を開始できません: \(error.localizedDescription)")
            }
        }
    }

    /// 録音準備（armed）中に、音声検知や確認を待たずに録音へ入る。カレンダー由来のタイトル・参加者は保つ。
    func startNow() {
        guard let session, sessionState == .armed else { return }
        awaitingStartConfirmation = false
        Task {
            do { try await session.startNow() } catch {
                operationError = "録音を開始できません: \(error.localizedDescription)"
                appendEvent(operationError ?? error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        guard let session else { return }
        awaitingStartConfirmation = false
        Task { await session.stop() }
    }

    func retryPipeline(meetingId: String) {
        guard let session else { return }
        Task {
            do { try await session.retryPipeline(meetingId: meetingId) }
            catch {
                operationError = "再実行できません: \(error.localizedDescription)"
                appendEvent(operationError ?? error.localizedDescription)
            }
        }
    }

    private func startAutoRecordingChecks() {
        autoStartTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkArmCondition()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        autoStartObservers.append(NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkArmCondition() }
        })
        autoStartObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.checkArmCondition() }
        })
    }

    /// 対象アプリを起動済みでも、時計・起動・復帰・予定変更から同じ条件を再評価する。
    func checkArmCondition() async {
        guard let session, let store, !checkingArm, !startingRecording,
              sessionState == .idle, settings.autoStartOnAudio, !needsOnboarding else { return }
        checkingArm = true
        defer { checkingArm = false }
        guard await session.state == .idle else { return }
        refreshCandidates()
        let now = Date()
        let scheduler = AutoRecordingScheduler(store: store)
        for candidate in candidates where candidate.startDate <= now.addingTimeInterval(300) && candidate.endDate > now {
            do {
                guard try scheduler.claim(eventId: candidate.id, start: candidate.startDate, end: candidate.endDate,
                                          enabled: settings.autoStartOnAudio, appRunning: detector.isTargetRunning(), idle: true) else { continue }
                var info = candidate.pendingInfo
                info.privacyMode = privacyModeForNextMeeting
                try await session.arm(info)
                AppModel.postNotification(title: "録音準備", body: settings.confirmBeforeAutoStart
                    ? "\(candidate.title) の音声を検知したら開始を確認します"
                    : "\(candidate.title) の音声を検知したら録音を開始します")
            } catch {
                appendEvent("録音準備に失敗: \(error.localizedDescription)。手動で開始し直してください")
            }
            return
        }
    }

    func refreshCandidates() {
        candidates = calendar.candidates(calendarIdentifiers: settings.calendarIdentifiers)
    }

    /// 今日の Meet / Teams の予定（開始順、終わった予定も含む）。メニューバーの「予定」。
    func todaySchedule(now: Date = Date()) -> [CalendarCandidate] {
        let startOfDay = Calendar.current.startOfDay(for: now)
        return calendar.candidates(now: startOfDay, before: 0, after: 86_400 - 1, calendarIdentifiers: settings.calendarIdentifiers)
            .sorted { $0.startDate < $1.startDate }
    }

    func defaultTitle() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日 H:mm"
        let apps = detector.runningTargets().compactMap(\.localizedName).first ?? "会議"
        return "\(apps) \(formatter.string(from: Date()))"
    }

    /// 録音対象として設定されているアプリのうち、起動しているもの（開始前の選択用）。
    func runningTargetApps() -> [(bundleID: String, name: String)] {
        var seen: Set<String> = []
        return detector.runningTargets().compactMap { app in
            guard let id = app.bundleIdentifier else { return nil }
            let target = settings.targetBundleIdentifiers.first { BundleIDMatcher.matches(id, target: $0) } ?? id
            guard !seen.contains(target) else { return nil }
            seen.insert(target)
            return (target, app.localizedName ?? target)
        }
    }

    private func handleState(_ state: SessionState, meeting: MeetingRecord?) {
        sessionState = state
        currentMeeting = meeting
        if state != .armed { awaitingStartConfirmation = false }
        if state == .recording, selectedMeetingId == nil, let meeting { selectedMeetingId = meeting.id }
        if state == .failed, let meeting {
            selectedMeetingId = meeting.id
            AppModel.postNotification(title: "録音・後処理に失敗しました", body: "\(meeting.title) の保存済みデータを確認してください", meetingId: meeting.id)
        }
        if state == .idle {
            clearLiveVolatile()
            if rebuildAfterRecording { rebuildPipeline() }
        }
        updateElapsedTicker()
    }

    private func updateElapsedTicker() {
        if sessionState == .recording || sessionState == .finalizing || sessionState == .armed {
            guard elapsedTask == nil else { return }
            // 値を替えるたびに表示する画面がレイアウトをやり直すので、変わったときだけ、秒の切り替わりの直後に 1 回替える（G7）
            elapsedTask = Task { [weak self] in
                while !Task.isCancelled {
                    var wait = 1.0
                    if let session = self?.session {
                        let elapsed = await session.snapshot().elapsedSeconds
                        self?.showElapsed(elapsed)
                        // 1 秒ずつ待つと読む時刻が少しずつずれ、表示の秒がときどき飛ぶ
                        if elapsed > 0 { wait = 1 - elapsed.truncatingRemainder(dividingBy: 1) + 0.02 }
                    }
                    try? await Task.sleep(for: .seconds(wait))
                }
            }
        } else {
            elapsedTask?.cancel()
            elapsedTask = nil
            menuBarElapsedSeconds = 0
            panelElapsedSeconds = 0
            windowElapsedSeconds = 0
        }
    }

    private func showElapsed(_ elapsed: Double) {
        if menuBarElapsedSeconds != elapsed { menuBarElapsedSeconds = elapsed }
        if visibleElapsedSurfaces.contains(.panel), panelElapsedSeconds != elapsed { panelElapsedSeconds = elapsed }
        if visibleElapsedSurfaces.contains(.window), windowElapsedSeconds != elapsed { windowElapsedSeconds = elapsed }
    }

    /// パネル・メインウィンドウが見え始めた / 隠れた。見え始めたら経過時間をすぐ最新にする。
    func setElapsedSurface(_ surface: ElapsedSurface, visible: Bool) {
        if visible { visibleElapsedSurfaces.insert(surface) } else { visibleElapsedSurfaces.remove(surface) }
        guard visible, elapsedTask != nil, let session else { return }
        Task { [weak self] in
            let elapsed = await session.snapshot().elapsedSeconds
            // 隠れていた間の古い値から転がさず、今の値をそのまま出す
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { self?.showElapsed(elapsed) }
        }
    }

    private func handleStartConfirmationRequest(_ meeting: MeetingRecord?) {
        awaitingStartConfirmation = true
        AppModel.postNotification(
            title: "会議の音声を検知しました",
            body: "\(meeting?.title ?? "会議") の録音を開始しますか？",
            meetingId: meeting?.id,
            category: AppModel.confirmStartCategoryIdentifier
        )
    }

    private func handleLive(meetingId: String, track: String, segment: LiveSegment) {
        guard currentMeeting?.id == meetingId else { return }
        if segment.isFinal {
            pendingVolatile[track] = nil
            liveVolatile[track] = ""
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { liveLines.append(LiveLine(track: track, start: segment.start, text: text)) }
            if liveLines.count > 500 { liveLines.removeFirst(liveLines.count - 500) }
        } else {
            pendingVolatile[track] = segment.text
            scheduleVolatileFlush()
        }
    }

    /// 途中経過の字幕は 1 秒に 4 回までにまとめて画面へ出す（G7）。
    /// SpeechAnalyzer は 1 文字ごとに途中経過を返すので、そのまま出すと字幕欄の組み直しとスクロールが走り続ける。
    private func scheduleVolatileFlush() {
        guard volatileFlush == nil else { return }
        volatileFlush = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.volatileFlush = nil
            for (track, text) in self.pendingVolatile { self.liveVolatile[track] = text }
            self.pendingVolatile = [:]
        }
    }

    @ObservationIgnored private var recordingSurfaces: Set<String> = []

    /// 録音を表示している画面（録音中のウィンドウ・メニューバーのパネル）を録音の診断ログに残す（G7: 画面を出しているときの CPU を分けて見る）。
    func setRecordingSurface(_ name: String, visible: Bool) {
        if visible { recordingSurfaces.insert(name) } else { recordingSurfaces.remove(name) }
        let state = recordingSurfaces.isEmpty ? "none" : recordingSurfaces.sorted().joined(separator: "+")
        Task { await session?.setUIState(state) }
    }

    private func clearLiveVolatile() {
        volatileFlush?.cancel()
        volatileFlush = nil
        pendingVolatile = [:]
        liveVolatile = [:]
    }

    func appendEvent(_ message: String) {
        events.append("\(JSONCoding.iso8601Local(Date()).suffix(14).prefix(8)) \(message)")
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }

    func clearEvents() { events = [] }

    // MARK: - Meetings list / search

    private func observePostProcessingJobs() {
        jobsObservation?.cancel()
        guard let store else { return }
        jobsObservation = Task { [weak self] in
            do {
                for try await jobs in store.postProcessingJobsObservation().values(in: store.writer) {
                    self?.postProcessingJobs = jobs
                }
            } catch { self?.appendEvent("後処理一覧の監視に失敗: \(error.localizedDescription)") }
        }
    }

    private func handlePostProcessing(_ event: PostProcessingQueue.Event) {
        switch event {
        case let .completed(id, warnings):
            appendEvent("後処理完了: \(id)")
            for (step, message) in warnings { appendEvent("後処理の警告 \(step.rawValue): \(message)") }
            if !warnings.isEmpty {
                let title = (try? store?.meeting(id: id))?.title ?? "会議"
                let steps = warnings.keys.map(\.title).sorted().joined(separator: "・")
                AppModel.postNotification(title: "\(steps)に失敗しました", body: "\(title) の文字起こしは保存済みです。会議画面からやり直せます。", meetingId: id)
            }
        case let .failed(id, message):
            appendEvent("後処理失敗: \(id): \(message)")
            let title = (try? store?.meeting(id: id))?.title ?? "会議"
            AppModel.postNotification(title: "後処理に失敗しました", body: "\(title) は保存済みです。会議画面から再実行できます。", meetingId: id)
        case let .unavailable(message):
            operationError = "後処理を開始できません: \(message)"
            appendEvent(operationError ?? message)
        }
    }

    private func observeTags() {
        tagsObservation?.cancel()
        guard let store else { return }
        tagsObservation = Task { [weak self] in
            do {
                for try await tags in store.tagsObservation().values(in: store.writer) {
                    self?.tags = tags
                    // 選択中のタグが消えたら「すべて」へ戻す
                    if let self, case let .tag(tag) = self.selectedItem, !tags.contains(where: { $0.tag == tag }) {
                        self.select(.folder(.all))
                    }
                }
            } catch {
                self?.appendEvent("タグ一覧の監視に失敗: \(error.localizedDescription)")
            }
        }
    }

    /// 会議リストの右クリックなどからタグを付け外しする。
    func toggleTag(_ tag: String, for meeting: MeetingRecord) {
        guard let store else { return }
        var tags = meeting.tags
        if let index = tags.firstIndex(of: tag) { tags.remove(at: index) } else { tags.append(tag) }
        do { try store.setMeetingTags(id: meeting.id, tags: tags) } catch { operationError = "タグを保存できません: \(error.localizedDescription)" }
    }

    private func observeMeetings() {
        meetingsObservation?.cancel()
        guard let store else { return }
        let filter = selectedItem.filter
        meetingsObservation = Task { [weak self] in
            do {
                for try await snapshot in store.meetingListObservation(filter).values(in: store.writer) {
                    self?.meetings = snapshot.meetings
                    self?.meetingPreviews = snapshot.previews
                }
            } catch {
                self?.appendEvent("会議一覧の監視に失敗: \(error.localizedDescription)")
            }
        }
    }

    private func observeRecentMeetings() {
        recentObservation?.cancel()
        guard let store else { return }
        recentObservation = Task { [weak self] in
            do {
                for try await meetings in store.meetingsObservation(.all, limit: 8).values(in: store.writer) {
                    self?.recentMeetings = meetings
                }
            } catch {
                self?.appendEvent("最近の会議の監視に失敗: \(error.localizedDescription)")
            }
        }
    }

    /// パネルの集計範囲の起点（`panelWeeks` 週前の週の初め。前週比のためさらに 1 週前から）。
    private static func panelRangeStart(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return calendar.date(byAdding: .weekOfYear, value: -panelWeeks, to: weekStart) ?? weekStart
    }

    private func observePanelMeetings() {
        panelObservation?.cancel()
        guard let store else { return }
        let since = AppModel.panelRangeStart()
        panelMeetingsSince = since
        panelObservation = Task { [weak self] in
            do {
                for try await meetings in store.meetingsObservation(.since(since), limit: 2000).values(in: store.writer) {
                    self?.panelMeetings = meetings
                }
            } catch {
                self?.appendEvent("会議時間の集計の監視に失敗: \(error.localizedDescription)")
            }
        }
    }

    /// 週が進んだら集計範囲を付け直す（常駐が長くても古い会議を読み続けない）。
    func refreshPanelMeetingsIfNeeded() {
        guard let since = panelMeetingsSince, since < AppModel.panelRangeStart() else { return }
        observePanelMeetings()
    }

    func select(_ item: SidebarItem) {
        selectedItem = item
        observeMeetings()
    }

    func selectFolder(_ folder: SmartFolder) {
        select(.folder(folder))
    }

    /// 入力を 200 ms まとめ、DB 検索はバックグラウンドで行う。
    func runSearch() {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let results = await Task.detached(priority: .userInitiated) { () -> [SearchResult] in
                (try? store.search(query)) ?? []
            }.value
            guard !Task.isCancelled else { return }
            self?.searchResults = results
            self?.isSearching = false
        }
    }

    func meeting(id: String) -> MeetingRecord? {
        meetings.first { $0.id == id } ?? recentMeetings.first { $0.id == id } ?? (try? store?.meeting(id: id)) ?? nil
    }

    func deleteMeeting(_ meeting: MeetingRecord) {
        guard let store else { return }
        do {
            guard canDeleteMeeting(meeting) else { throw StoreError.meetingBusy(meeting.id) }
            try store.deleteMeeting(id: meeting.id)
        } catch {
            operationError = error.localizedDescription
            appendEvent("会議の削除に失敗: \(error.localizedDescription)")
        }
        do {
            if try store.meeting(id: meeting.id) == nil {
                notesDrafts.removeValue(forKey: meeting.id)?.discard()
                if playback.meetingId == meeting.id { playback.stop() }
                if selectedMeetingId == meeting.id { selectedMeetingId = nil }
            }
        } catch { operationError = error.localizedDescription }
    }

    func canDeleteMeeting(_ meeting: MeetingRecord) -> Bool {
        meeting.meetingStatus != .recording && meeting.meetingStatus != .finalizing
            && !(isRecording && currentMeeting?.id == meeting.id)
    }

    func notesDraft(for meetingId: String) -> UserNotesDraft {
        if let draft = notesDrafts[meetingId] { return draft }
        let store = store
        let draft = UserNotesDraft { text in
            guard let store else { throw StoreError.notFound("データベース") }
            try store.updateUserNotes(meetingId: meetingId, markdown: text)
        }
        notesDrafts[meetingId] = draft
        return draft
    }

    /// 会議詳細のモデル。画面ごとに作り、監視は画面の寿命に合わせる。
    func makeDetailModel(meetingId: String) -> MeetingDetailModel? {
        guard let store else { return nil }
        return MeetingDetailModel(
            store: store,
            pipeline: pipeline,
            meetingId: meetingId,
            notesDraft: notesDraft(for: meetingId),
            voicesDirectory: Store.applicationSupportDirectory().appendingPathComponent("voices", isDirectory: true)
        )
    }

    // MARK: - Window / activation

    /// メインウィンドウか初回の案内を出している間だけ Dock とアプリメニューを持つ（⌘Tab・Edit メニューが使える）。閉じたらメニューバー常駐に戻る。
    func setMainWindowVisible(_ visible: Bool) {
        setElapsedSurface(.window, visible: visible)
        setWindowVisible("main", visible: visible)
    }

    func setOnboardingVisible(_ visible: Bool) {
        setWindowVisible("onboarding", visible: visible)
    }

    @ObservationIgnored private var visibleWindows: Set<String> = []

    private func setWindowVisible(_ id: String, visible: Bool) {
        if visible { visibleWindows.insert(id) } else { visibleWindows.remove(id) }
        let policy: NSApplication.ActivationPolicy = visibleWindows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if visible { NSApp.activate() }
    }

    // MARK: - URL scheme

    enum DeepLink: Equatable {
        case meeting, settings, ignored
    }

    /// minutes://meeting/<id>?seg=<n> と minutes://settings?tab=<recording|providers|export|calendar|people|appearance|diagnostics|about>。
    /// 旧 tab=keys（API キーはプロバイダのタブに統合した）はプロバイダを開く。
    @discardableResult
    func handle(url: URL) -> DeepLink {
        guard url.scheme == "minutes" else { return .ignored }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "meeting":
            let id = url.pathComponents.dropFirst().first ?? ""
            guard !id.isEmpty else { return .ignored }
            select(.folder(.all))
            selectedMeetingId = id
            if let seg = query.first(where: { $0.name == "seg" })?.value, let segId = Int64(seg) {
                pendingSegmentId = segId
            }
            return .meeting
        case "settings":
            let tab = query.first(where: { $0.name == "tab" })?.value
            requestedSettingsTab = tab == "keys" ? .providers : tab.flatMap(SettingsTab.init(rawValue:)) ?? .recording
            return .settings
        default:
            return .ignored
        }
    }

    // MARK: - Housekeeping（起動時と 10 分ごと: 再送と音声保持）

    private func startHousekeeping() {
        housekeepingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.housekeep()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    private func housekeep() async {
        guard let store, let pipeline else { return }
        await postProcessingQueue?.start()
        do {
            for message in try store.retryPendingAudioDeletions() { appendEvent(message) }
        } catch { appendEvent("削除の再試行に失敗: \(error.localizedDescription)") }
        let report = await pipeline.retryPendingExports()
        for line in report { appendEvent("export retry: \(line)") }
        do {
            let purged = try AudioRetention.purge(store: store, retentionDays: settings.audioRetentionDays, managedRoot: settings.audioRootDirectoryURL)
            if !purged.purgedMeetingIds.isEmpty { appendEvent("音声を削除: \(purged.purgedMeetingIds.count) 件") }
        } catch { appendEvent("音声の保持処理に失敗: \(error.localizedDescription)") }
    }

    // MARK: - Notifications

    private func configureNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: AppModel.startRecordingActionIdentifier, title: "録音を開始", options: [.foreground])
        let category = UNNotificationCategory(identifier: AppModel.confirmStartCategoryIdentifier, actions: [start], intentIdentifiers: [])
        center.setNotificationCategories([category])
        notificationDelegate.onOpenMeeting = { [weak self] meetingId in
            Task { @MainActor in
                guard let self else { return }
                if let meetingId { self.handle(url: URL(string: "minutes://meeting/\(meetingId)")!) }
                self.notificationDelegate.openMainWindow?()
            }
        }
        notificationDelegate.onStartRecording = { [weak self] in
            Task { @MainActor in self?.startNow() }
        }
        center.delegate = notificationDelegate
    }

    /// 通知からウィンドウを開く手段は Scene 側が持つ（openWindow）。
    func setNotificationWindowOpener(_ opener: @escaping @MainActor () -> Void) {
        notificationDelegate.openMainWindow = opener
    }

    static func postNotification(title: String, body: String, meetingId: String? = nil, category: String? = nil) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let meetingId { content.userInfo["meetingId"] = meetingId }
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// 通知のクリック・アクションをアプリの操作に変換する。前面にあるときもバナーを出す。
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onOpenMeeting: (@Sendable (String?) -> Void)?
    var onStartRecording: (@Sendable () -> Void)?
    var openMainWindow: (@MainActor () -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let meetingId = response.notification.request.content.userInfo["meetingId"] as? String
        if response.actionIdentifier == AppModel.startRecordingActionIdentifier {
            onStartRecording?()
            return
        }
        onOpenMeeting?(meetingId)
    }
}
