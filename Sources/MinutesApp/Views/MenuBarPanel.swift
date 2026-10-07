import AppKit
import EventKit
import MinutesCore
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case overview, schedule, recent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概要"
        case .schedule: "予定"
        case .recent: "最近"
        }
    }
}

/// メニューバーのパネル（SPEC §10.1）: 録音の状態と開始・停止、今日・今週の会議時間、今日の予定、最近の会議。
/// 表示部品（`PanelHeader` など）はモデルに依存せず値だけを受け取る。
struct MenuBarPanel: View {
    static let width: CGFloat = 360
    static let contentHeight: CGFloat = 364

    /// 待機中に録音する予定。自動は「今の会議」候補の先頭。
    private enum CandidateChoice: Equatable {
        case automatic, none, event(String)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("menuBarPanel.tab") private var tab: PanelTab = .overview
    @State private var choice: CandidateChoice = .automatic
    @State private var snapshot: SessionSnapshot?
    @State private var schedule: [CalendarCandidate] = []
    @State private var weekOffset = 0

    private var chosenCandidate: CalendarCandidate? {
        switch choice {
        case .automatic: model.candidates.first
        case .none: nil
        case let .event(id): model.candidates.first { $0.id == id }
        }
    }

    /// 録音準備中（まだ会議が始まっていない）の会議。録音の行は先に作られるが、集計・予定の録音済み・最近には出さない。
    private var armedMeetingId: String? {
        model.sessionState == .armed ? model.currentMeeting?.id : nil
    }

    /// 集計に使う会議。録音準備中の会議は数えない。
    private var countedMeetings: [MeetingRecord] {
        guard let armedMeetingId else { return model.panelMeetings }
        return model.panelMeetings.filter { $0.id != armedMeetingId }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    MinutesBrandLockup(height: 18)
                    header
                    timerRow
                    if let error = model.operationError {
                        PanelNotice(text: error, onClose: { model.operationError = nil })
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    SegmentedTabs(tabs: PanelTab.allCases, selection: $tab, title: \.title)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                ScrollView {
                    tabContent(now: context.date)
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .frame(height: MenuBarPanel.contentHeight)
                footer(now: context.date)
            }
        }
        .frame(width: MenuBarPanel.width)
        .animation(.smooth(duration: 0.25), value: model.operationError)
        .animation(.smooth(duration: 0.25), value: model.sessionState)
        .task { await refreshLoop() }
        .task(id: model.sessionState) { await pollSnapshot() }
        .onAppear {
            model.setRecordingSurface("panel", visible: true)
            model.setElapsedSurface(.panel, visible: true)
        }
        .onDisappear {
            model.setRecordingSurface("panel", visible: false)
            model.setElapsedSurface(.panel, visible: false)
        }
    }

    // MARK: - 見出しと操作

    private var header: some View {
        let state = model.sessionState
        let meeting = model.currentMeeting
        return PanelHeader(
            tile: tile,
            title: model.isRecording ? (meeting?.title ?? "録音準備中") : (chosenCandidate?.title ?? "新しい会議"),
            subtitle: subtitle,
            subtitleIsWarning: subtitleIsWarning,
            hasMenu: !model.isRecording && !model.candidates.isEmpty
        ) {
            Button { choice = .none } label: { choiceLabel("予定なし（手動）", selected: chosenCandidate == nil) }
            Divider()
            ForEach(model.candidates) { candidate in
                Button { choice = .event(candidate.id) } label: {
                    choiceLabel("\(candidate.title)（\(Formatting.timeRange(candidate.startDate, candidate.endDate))）", selected: chosenCandidate?.id == candidate.id)
                }
            }
        } trailing: {
            if state == .recording || state == .finalizing, let meeting {
                HStack(spacing: 6) {
                    LiveLanguageMenu(preparation: snapshot?.livePreparation)
                    HStack(spacing: 5) {
                        if meeting.privacy == .localOnly {
                            Image(systemName: "lock.fill").help("ローカルのみ（クラウドへ送信しない）")
                        }
                        Text("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) から")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }
            } else if state == .armed {
                LiveLanguageMenu(preparation: snapshot?.livePreparation)
            } else if !model.isRecording {
                HStack(spacing: 6) {
                    NextLanguageMenu(choice: Binding(get: { model.languageForNextMeeting }, set: { model.languageForNextMeeting = $0 }))
                    PrivacyMenu(mode: Binding(get: { model.privacyModeForNextMeeting }, set: { model.privacyModeForNextMeeting = $0 }))
                }
            }
        }
    }

    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        Group {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var tile: TintedTile {
        switch model.sessionState {
        case .armed:
            return TintedTile(systemImage: "waveform.badge.magnifyingglass", tint: Palette.amber)
        case .recording:
            return TintedTile(systemImage: (model.currentMeeting?.meetingPlatform ?? .other).symbol, tint: Palette.record, pulse: true)
        case .finalizing:
            return TintedTile(systemImage: "hourglass", tint: Palette.periwinkle)
        default:
            if let candidate = chosenCandidate {
                return TintedTile(systemImage: candidate.platform.symbol, tint: Palette.color(forKey: candidate.title))
            }
            return TintedTile(systemImage: "waveform", tint: .secondary)
        }
    }

    private var tappedApps: String? {
        guard let names = snapshot?.tappedProcessNames, !names.isEmpty else { return nil }
        return Array(Set(names)).sorted().joined(separator: ", ")
    }

    private var subtitle: String {
        switch model.sessionState {
        case .armed:
            return model.awaitingStartConfirmation ? "会議の音声を検知しました" : "会議の音声を検知したら録音を開始します"
        case .recording:
            if let names = snapshot?.interruptedTrackNames {
                return "\(names)が途切れています · 録音は継続中"
            }
            if let status = snapshot?.livePreparation?.statusText { return status }
            return ["録音中", tappedApps].compactMap { $0 }.joined(separator: " · ")
        case .finalizing:
            return "録音の終了を待っています"
        default:
            let apps = model.runningTargetApps().map(\.name)
            let time = chosenCandidate.map { Formatting.timeRange($0.startDate, $0.endDate) }
            let target = apps.isEmpty ? "対象アプリが起動していません" : "\(apps.joined(separator: ", ")) を録音"
            return [time, target].compactMap { $0 }.joined(separator: " · ")
        }
    }

    private var subtitleIsWarning: Bool {
        switch model.sessionState {
        case .armed: model.awaitingStartConfirmation
        case .idle, .done, .failed: model.runningTargetApps().isEmpty
        case .recording: snapshot?.interruptedTracks.isEmpty == false || snapshot?.livePreparation?.isFailure == true
        default: false
        }
    }

    /// タイマーと操作。左の補助操作（キャンセル・字幕・ウィンドウ）は状態ごとに差し替え、右の主操作は 1 つのピルが担う。
    @ViewBuilder
    private var timerRow: some View {
        let state = model.sessionState
        HStack(alignment: .center, spacing: 8) {
            BigTimerText(seconds: model.isRecording ? model.panelElapsedSeconds : 0, isDimmed: state == .armed || !model.isRecording)
                .frame(maxWidth: .infinity, alignment: .leading)
            switch state {
            case .armed:
                Button { model.stopRecording() } label: { Image(systemName: "xmark") }
                    .buttonStyle(CircleIconButtonStyle())
                    .help("録音準備をキャンセル（⇧⌘.）")
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            case .recording:
                if let scheduled = scheduledSlot {
                    ScheduleProgressPill(start: scheduled.startDate, end: scheduled.endDate, now: Date())
                } else {
                    Button { openMain(meetingId: model.currentMeeting?.id) } label: { Image(systemName: "captions.bubble") }
                        .buttonStyle(CircleIconButtonStyle())
                        .help("ライブ字幕とメモをウィンドウで表示")
                }
            case .finalizing:
                EmptyView()
            default:
                Button { openMain() } label: { Image(systemName: "macwindow") }
                    .buttonStyle(CircleIconButtonStyle())
                    .help("ウィンドウを開く（⇧⌘M）")
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
            primaryPill(state)
        }
    }

    /// 主操作のピル。録音 / 今すぐ開始 / 停止 / 録音を終了 を 1 つのボタンが担い、状態が変わるとカプセルが幅を変えながら記号と文字が
    /// 入れ替わる（状態ごとに別のボタンを差し替えると、同じ位置の同じ形が別物として消えて現れる）。動きはパネル全体の `.animation` に従う。
    private func primaryPill(_ state: SessionState) -> some View {
        let pill: PrimaryPill = switch state {
        case .armed:
            PrimaryPill(glyph: .record, title: model.awaitingStartConfirmation ? "録音を開始" : "今すぐ開始",
                        help: "音声の検知を待たずに録音を開始（⇧⌘R）", shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]))
        case .recording:
            PrimaryPill(glyph: .stop, title: "停止", help: "録音を停止（⇧⌘.）", shortcut: KeyboardShortcut(".", modifiers: [.command, .shift]))
        case .finalizing:
            PrimaryPill(glyph: .stop, title: "録音を終了", help: "自動停止の猶予を待たずに録音を終了")
        default:
            PrimaryPill(glyph: .record, title: "録音",
                        help: "録音を開始（⇧⌘R、プライバシー: \(model.privacyModeForNextMeeting.title)）", shortcut: KeyboardShortcut("r", modifiers: [.command, .shift]))
        }
        return Button {
            switch state {
            case .armed: model.startNow()
            case .recording, .finalizing: model.stopRecording()
            default: startRecording()
            }
        } label: {
            HStack(spacing: 8) {
                PillGlyph(kind: pill.glyph)
                Text(pill.title)
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(PillButtonStyle())
        // 待機中に開始処理が走っている間は押せない
        .disabled(state != .armed && state != .recording && state != .finalizing && model.isRecording)
        .help(pill.help)
        .keyboardShortcut(pill.shortcut)
    }

    /// 録音中の会議がカレンダーの予定なら、その予定（残り時間の表示用）。
    private var scheduledSlot: CalendarCandidate? {
        guard let eventId = model.currentMeeting?.calendarEventId else { return nil }
        return model.candidates.first { $0.id == eventId } ?? schedule.first { $0.id == eventId }
    }

    // MARK: - タブ

    @ViewBuilder
    private func tabContent(now: Date) -> some View {
        switch tab {
        case .overview:
            let calendar = Calendar.current
            let weekDate = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: now) ?? now
            OverviewSection(
                today: MeetingTimeStats.day(now, meetings: countedMeetings, now: now),
                week: MeetingTimeStats.week(containing: weekDate, meetings: countedMeetings, now: now),
                weekTitle: weekTitle(weekDate),
                now: now,
                canGoBack: weekOffset > -AppModel.panelWeeks + 1,
                canGoForward: weekOffset < 0,
                onBack: { withAnimation(.snappy) { weekOffset -= 1 } },
                onForward: { withAnimation(.snappy) { weekOffset += 1 } },
                onOpen: { openMain(meetingId: $0) }
            )
        case .schedule:
            ScheduleSection(
                items: schedule.map { candidate in
                    ScheduleSection.Item(
                        candidate: candidate,
                        recordedMeetingId: countedMeetings.first { $0.calendarEventId == candidate.id && Calendar.current.isDate($0.startedAt, inSameDayAs: candidate.startDate) }?.id,
                        sessionState: model.currentMeeting?.calendarEventId == candidate.id ? model.sessionState : nil
                    )
                },
                now: now,
                calendarAuthorized: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                canRecord: !model.isRecording,
                onRecord: { candidate in
                    var info = candidate.pendingInfo
                    info.privacyMode = model.privacyModeForNextMeeting
                    model.startRecording(info)
                },
                onOpen: { openMain(meetingId: $0) },
                onOpenCalendarSettings: { openSettingsWindow(tab: .calendar) }
            )
        case .recent:
            RecentSection(
                meetings: Array(model.recentMeetings.filter { $0.id != armedMeetingId }.prefix(6)),
                now: now,
                onOpen: { openMain(meetingId: $0) },
                onShowAll: { openMain() }
            )
        }
    }

    private func weekTitle(_ date: Date) -> String {
        switch weekOffset {
        case 0: return "今週"
        case -1: return "先週"
        default:
            let start = Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            return start.formatted(Date.FormatStyle(locale: Formatting.ja).month().day()) + "の週"
        }
    }

    // MARK: - フッター

    private func footer(now: Date) -> some View {
        let upcoming = schedule.first { $0.endDate > now && !(model.isRecording && model.currentMeeting?.calendarEventId == $0.id) }
        let text: String
        if let upcoming {
            let prefix = upcoming.startDate <= now ? "進行中" : "次の会議"
            text = "\(prefix) \(upcoming.startDate.formatted(date: .omitted, time: .shortened)) \(upcoming.title)"
        } else {
            text = "この後の予定はありません"
        }
        return PanelFooter(text: text, symbol: "calendar.badge.clock", jobs: model.postProcessingSummary) {
            Menu {
                Picker("テーマ", selection: Binding(get: { model.settings.appearance }, set: { model.setAppearance($0) })) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Label(appearance.title, systemImage: appearance.symbol).tag(appearance)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                PanelMenuIcon(systemName: model.settings.appearance.symbol)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("テーマ（\(model.settings.appearance.title)）")
            Menu {
                Button("ウィンドウを開く") { openMain() }
                Button("参加者への告知文をコピー") { RecordingNotice.copy(model.settings.resolvedRecordingNotice) }
                Button("設定…") { openSettingsWindow() }
                if model.updates.isAvailable {
                    Divider()
                    Button(model.updates.pendingVersion.map { "新しい版（\($0)）を入れる…" } ?? "アップデートを確認…") {
                        model.updates.checkForUpdates()
                    }
                }
                Divider()
                Button("Minutes を終了") { NSApp.terminate(nil) }
            } label: {
                PanelMenuIcon(systemName: "slider.horizontal.3")
                    // 予定の確認で見つけた新しい版があれば、メニューに印を付ける
                    .overlay(alignment: .topTrailing) {
                        if model.updates.pendingVersion != nil {
                            Circle().fill(Palette.periwinkle).frame(width: 6, height: 6).offset(x: 1, y: -1)
                        }
                    }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.updates.pendingVersion.map { "新しい版（\($0)）があります" } ?? "ウィンドウ・設定・終了")
        }
    }

    // MARK: - 操作

    private func startRecording() {
        guard let candidate = chosenCandidate else {
            model.startRecording()
            return
        }
        var info = candidate.pendingInfo
        info.privacyMode = model.privacyModeForNextMeeting
        model.startRecording(info)
    }

    private func openMain(meetingId: String? = nil) {
        if let meetingId {
            model.selectFolder(.all)
            model.selectedMeetingId = meetingId
        }
        openWindow(id: "main")
        model.setMainWindowVisible(true)
    }

    private func openSettingsWindow(tab: SettingsTab? = nil) {
        if let tab { model.requestedSettingsTab = tab }
        openSettings()
        NSApp.activate()
    }

    /// 予定と「今の会議」候補を 1 分ごと・予定の変更時に読み直す（表示中のみ）。
    private func refreshLoop() async {
        let changes = NotificationCenter.default.notifications(named: .EKEventStoreChanged)
        let watcher = Task { @MainActor in
            for await _ in changes {
                model.refreshCandidates()
                schedule = model.todaySchedule()
            }
        }
        defer { watcher.cancel() }
        while !Task.isCancelled {
            model.refreshCandidates()
            model.refreshPanelMeetingsIfNeeded()
            schedule = model.todaySchedule()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// 録音対象のアプリ名はセッションから直接読む（1 秒ごと、録音セッション中のみ）。
    /// 状態は表示が変わるときだけ替える（替えるたびにパネル全体のレイアウトをやり直す。経過時間は AppModel が届ける。G7）。
    private func pollSnapshot() async {
        guard model.isRecording else {
            snapshot = nil
            return
        }
        while !Task.isCancelled {
            let latest = await model.session?.snapshot()
            if !SessionSnapshot.sameDisplay(snapshot, latest) { snapshot = latest }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

// MARK: - 表示部品（値だけを受け取る）

/// 見出し: タイル・会議名（予定を選ぶメニュー）・状態の副題・右端の情報。
struct PanelHeader<MenuItems: View, Trailing: View>: View {
    let tile: TintedTile
    let title: String
    let subtitle: String
    var subtitleIsWarning = false
    var hasMenu = false
    @ViewBuilder var menuItems: MenuItems
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            tile
            VStack(alignment: .leading, spacing: 2) {
                if hasMenu {
                    Menu {
                        menuItems
                    } label: {
                        titleLabel(showsChevron: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    // 横は固定しない。長い予定名は省略して、パネルの幅（`MenuBarPanel.width`）を押し広げない
                    .fixedSize(horizontal: false, vertical: true)
                    .help("録音する予定を選ぶ")
                } else {
                    titleLabel(showsChevron: false)
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(subtitleIsWarning ? AnyShapeStyle(Palette.amber) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }

    private func titleLabel(showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
    }
}

/// 次の録音のプライバシー（見出しの右端）。
struct PrivacyMenu: View {
    @Binding var mode: PrivacyMode

    var body: some View {
        Menu {
            Picker("次の録音のプライバシー", selection: $mode) {
                ForEach(PrivacyMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HeaderCapsuleLabel(systemImage: mode.symbol, title: mode.title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("次の録音のプライバシー")
    }
}

/// 操作の失敗（閉じるまで残す）。
struct PanelNotice: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.record)
            Text(text)
                .font(.system(size: 12))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("閉じる")
        }
        .padding(10)
        .background(Palette.record.opacity(0.13), in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// 概要: 今日の会議の内訳と、1 週間の会議時間。
struct OverviewSection: View {
    let today: MeetingTimeStats.Day
    let week: MeetingTimeStats.Week
    let weekTitle: String
    let now: Date
    var canGoBack = true
    var canGoForward = false
    var onBack: () -> Void = {}
    var onForward: () -> Void = {}
    var onOpen: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日")
                Spacer()
                if today.total > 0 {
                    Text(Formatting.duration(today.total)).monospacedDigit()
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            StackedBar(segments: today.entries.map { StackedBar.Segment(id: $0.meeting.id, value: $0.seconds, color: Palette.color(for: $0.meeting)) })
            if today.entries.isEmpty {
                Text("今日の会議はまだありません")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(today.entries, id: \.meeting.id) { entry in
                        Button { onOpen(entry.meeting.id) } label: {
                            BreakdownRow(
                                title: entry.meeting.title,
                                subtitle: entry.meeting.meetingStatus == .recording ? "録音中" : nil,
                                seconds: entry.seconds,
                                fraction: today.total > 0 ? entry.seconds / today.total : nil
                            ) {
                                // 色はバーの区切りと揃える（録音中は赤い点で示す）
                                PlatformIcon(platform: entry.meeting.meetingPlatform, size: 22, tint: Palette.color(for: entry.meeting))
                                    .overlay(alignment: .topTrailing) {
                                        if entry.meeting.meetingStatus == .recording {
                                            Circle().fill(Palette.record).frame(width: 8, height: 8).offset(x: 3, y: -3)
                                        }
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                        .help("\(Formatting.timeRange(entry.meeting.startedAt, entry.meeting.endedAt))（クリックで開く）")
                    }
                }
                .padding(.horizontal, -8)
            }
            Rectangle()
                .fill(Surface.hairline)
                .frame(height: 1)
                .padding(.vertical, 3)
            weekSummary
            WeekBarChart(columns: week.days.map { day in
                WeekBarChart.Column(
                    date: day.start,
                    segments: day.entries.map { StackedBar.Segment(id: $0.meeting.id, value: $0.seconds, color: Palette.color(for: $0.meeting)) },
                    isToday: Calendar.current.isDate(day.start, inSameDayAs: now),
                    isFuture: day.start > now
                )
            }, barHeight: 64)
        }
    }

    private var weekSummary: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("会議時間の合計")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(alignment: .center, spacing: 8) {
                    // 前の週（「9月14日の週」）で 10 時間を超えると入りきらない。数字を先に取り、前週比の方を縮める
                    DurationText(seconds: week.total, size: 24)
                        .layoutPriority(1)
                    if let change = week.change {
                        ChangeBadge(change: change)
                    }
                }
            }
            Spacer()
            HStack(spacing: 2) {
                Button(action: onBack) { Image(systemName: "chevron.left") }
                    .disabled(!canGoBack)
                    .help("前の週")
                Text(weekTitle)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44)
                Button(action: onForward) { Image(systemName: "chevron.right") }
                    .disabled(!canGoForward)
                    .help("次の週")
            }
            .buttonStyle(PanelIconButtonStyle(size: 24))
        }
    }
}

/// 前週比（↓ 12% 先週比）。幅が足りないときは「先週比」を省いて数字だけにする。
struct ChangeBadge: View {
    let change: Double

    var body: some View {
        let percent = Int((abs(change) * 100).rounded())
        HStack(spacing: 5) {
            Image(systemName: percent == 0 ? "equal" : (change < 0 ? "arrow.down" : "arrow.up"))
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Surface.raised, in: .circle)
            ViewThatFits(in: .horizontal) {
                Text(percent == 0 ? "先週と同じ" : "\(percent)% 先週比")
                Text(verbatim: "\(percent)%")
            }
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
        }
        .foregroundStyle(.secondary)
        .help("前週の同じ時点までの会議時間との比較")
    }
}

/// 予定: 今日の Meet / Teams の予定と、録音済みかどうか。現在時刻の線を挟む。
struct ScheduleSection: View {
    struct Item: Identifiable {
        let candidate: CalendarCandidate
        let recordedMeetingId: String?
        /// この予定が現在のセッションなら、その状態（armed を「準備中」と出すため）。
        let sessionState: SessionState?
        var id: String { candidate.id }
        /// 録音中・終了待ち。録音準備中（armed）はまだ会議が始まっていないので含めない。
        var isRecordingNow: Bool { sessionState == .recording || sessionState == .finalizing }
    }

    let items: [Item]
    let now: Date
    var calendarAuthorized = true
    var canRecord = true
    var onRecord: (CalendarCandidate) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }
    var onOpenCalendarSettings: () -> Void = {}

    /// 現在時刻の線を入れる位置（最初の未来の予定の前）。
    private var nowIndex: Int { items.firstIndex { $0.candidate.startDate > now } ?? items.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日の予定")
                Spacer()
                if !items.isEmpty { Text("\(items.count) 件").monospacedDigit() }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            if !calendarAuthorized {
                VStack(alignment: .leading, spacing: 8) {
                    Text("カレンダーへのアクセスが許可されていません。許可すると Meet / Teams の予定がここに並び、録音の候補になります。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Button("カレンダーの設定を開く", action: onOpenCalendarSettings)
                        .controlSize(.small)
                }
            } else if items.isEmpty {
                Text("今日の Meet / Teams の予定はありません")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index == nowIndex { nowLine }
                        row(item)
                    }
                    if nowIndex == items.count { nowLine }
                }
                .padding(.horizontal, -8)
            }
        }
    }

    private var nowLine: some View {
        HStack(spacing: 6) {
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.record)
                .frame(width: 44, alignment: .trailing)
            Circle().fill(Palette.record).frame(width: 5, height: 5)
            Rectangle().fill(Palette.record.opacity(0.6)).frame(height: 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .accessibilityLabel("現在 \(now.formatted(date: .omitted, time: .shortened))")
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        let candidate = item.candidate
        let isPast = candidate.endDate <= now
        let content = HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(candidate.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Text(Formatting.duration(candidate.endDate.timeIntervalSince(candidate.startDate)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 44, alignment: .trailing)
            PlatformIcon(platform: candidate.platform, size: 22, tint: Palette.color(forKey: candidate.title))
            Text(candidate.title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(isPast && item.recordedMeetingId == nil ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing(item, isPast: isPast)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 38)
        .contentShape(.rect)

        if let meetingId = item.recordedMeetingId, !item.isRecordingNow {
            Button { onOpen(meetingId) } label: { content }
                .buttonStyle(.plain)
                .hoverHighlight()
                .help("議事録を開く")
        } else {
            content
        }
    }

    @ViewBuilder
    private func trailing(_ item: Item, isPast: Bool) -> some View {
        let candidate = item.candidate
        if item.isRecordingNow {
            HStack(spacing: 5) {
                Circle().fill(Palette.record).frame(width: 7, height: 7)
                Text("録音中")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Palette.record)
        } else if item.sessionState == .armed {
            // 音声の検知か「今すぐ開始」で録音中に変わる
            HStack(spacing: 5) {
                Image(systemName: SessionState.armed.symbol)
                Text("準備中")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SessionState.armed.tint)
            .help(SessionState.armed.detail)
        } else if item.recordedMeetingId != nil {
            Label("録音済み", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.mint)
        } else if isPast {
            Text("録音なし")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        } else if canRecord, candidate.startDate <= now.addingTimeInterval(10 * 60) {
            Button { onRecord(candidate) } label: { MiniRecordLabel() }
                .buttonStyle(MiniPillButtonStyle())
                .help("この予定として録音を開始")
        }
    }
}

/// 最近: 最近の会議をカードで並べる。
struct RecentSection: View {
    let meetings: [MeetingRecord]
    let now: Date
    var onOpen: (String) -> Void = { _ in }
    var onShowAll: () -> Void = {}

    private var rows: [[MeetingRecord]] {
        stride(from: 0, to: meetings.count, by: 2).map { Array(meetings[$0..<min($0 + 2, meetings.count)]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近の会議")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onShowAll) {
                    HStack(spacing: 3) {
                        Text("すべて表示")
                        Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("ウィンドウで会議の一覧を開く")
            }
            if meetings.isEmpty {
                Text("会議はまだありません")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(rows, id: \.first?.id) { row in
                    GridRow {
                        ForEach(row) { meeting in
                            Button { onOpen(meeting.id) } label: { MeetingCard(meeting: meeting, now: now) }
                                .buttonStyle(.plain)
                                .hoverHighlight(cornerRadius: 12)
                        }
                        if row.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                    }
                }
            }
        }
    }
}

/// 会議のカード（タイトル・長さ・状態・日時）。
struct MeetingCard: View {
    let meeting: MeetingRecord
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                PlatformIcon(platform: meeting.meetingPlatform, size: 22, tint: Palette.color(for: meeting))
                Text(meeting.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(Formatting.duration(MeetingTimeStats.seconds(of: meeting, now: now)))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                    statusGlyph
                        .font(.system(size: 12))
                }
                Text(Formatting.relativeStart(meeting.startedAt, now: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, 30)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(.rect(cornerRadius: 12))
        .help(meeting.title)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch meeting.meetingStatus {
        case .done:
            Image(systemName: meeting.privacy == .localOnly ? "lock.fill" : "checkmark.circle.fill")
                .foregroundStyle(meeting.privacy == .localOnly ? AnyShapeStyle(.secondary) : AnyShapeStyle(Palette.mint))
                .help(meeting.privacy == .localOnly ? "完了（ローカルのみ）" : "完了")
        case .finalizing:
            Image(systemName: "circle.lefthalf.filled")
                .foregroundStyle(Palette.amber)
                .help("文字起こし・要約を作成中")
        case .recording:
            Image(systemName: "record.circle")
                .foregroundStyle(Palette.record)
                .help("録音中")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.record)
                .help("失敗（ウィンドウからやり直せます）")
        }
    }
}

/// 下端: 次の予定と、後処理の件数・テーマ・メニュー。
struct PanelFooter<Menus: View>: View {
    let text: String
    let symbol: String
    var jobs: String?
    @ViewBuilder var menus: Menus

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Surface.hairline).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let jobs {
                    // パネルは閉じても描き続けるので、点滅は `AnimatedSymbol` で描く
                    AnimatedSymbol(systemName: "hourglass", pointSize: 12, weight: .medium, color: Palette.amber, effect: .pulse)
                        .help(jobs + "（後処理中も次の会議を録音できます）")
                }
                menus
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .frame(height: 44)
        }
    }
}

/// フッターのメニューの記号（メニューは AppKit のボタンなので、見た目はラベル側で持つ）。
struct PanelMenuIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(.rect)
    }
}

/// パネルの小さなアイコンボタン（ホバーで面を出す）。
struct PanelIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        PanelIconButtonBody(configuration: configuration, size: size)
    }

    private struct PanelIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.48, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(configuration.isPressed ? Surface.pressed : (hovering ? Surface.hover : .clear), in: .rect(cornerRadius: size * 0.3, style: .continuous))
                .contentShape(.rect(cornerRadius: size * 0.3))
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}
