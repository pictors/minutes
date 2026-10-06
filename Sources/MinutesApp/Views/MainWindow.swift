import AppKit
import MinutesCore
import SwiftUI

/// 3 ペイン（SPEC §10.2）: スマートフォルダ + 検索 / 会議リスト / 議事録ビュー。
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
        } content: {
            ContentColumn()
        } detail: {
            DetailColumn()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SessionStatusBadge() }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { RecordToolbarButton() }
            // 会議の操作「⋯」は詳細画面ではなくここに置く（会議を切り替えるたびにツールバーを作り直さない）
            if let actions = model.meetingActions {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { MeetingActionsMenu(state: actions) }
            }
        }
        // ウィンドウを出している間は Dock とアプリメニューを持つ（⌘Tab、Edit メニュー）。閉じたら常駐に戻す。
        .onAppear {
            model.setMainWindowVisible(true)
            model.setNotificationWindowOpener {
                openWindow(id: "main")
                model.setMainWindowVisible(true)
            }
        }
        .onDisappear { model.setMainWindowVisible(false) }
        .onOpenURL { url in
            if model.handle(url: url) == .settings {
                openSettings()
                NSApp.activate()
            }
        }
        .alert("起動エラー", isPresented: .constant(model.startupError != nil)) {
            Button("Minutes を終了") { NSApp.terminate(nil) }
        } message: {
            Text((model.startupError ?? "") + "\n\nデータベースを開けないため、会議の保存・表示ができません。")
        }
        .alert("操作に失敗しました", isPresented: Binding(get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } })) {
            Button("OK") { model.operationError = nil }
            if model.operationError?.contains("許可") == true || model.operationError?.contains("権限") == true {
                Button("システム設定を開く") {
                    let message = model.operationError ?? ""
                    model.operationError = nil
                    SystemSettingsLink.openPrivacy(forError: message)
                }
            }
        } message: {
            Text(model.operationError ?? "")
        }
    }
}

enum SystemSettingsLink {
    static func openPrivacy(pane: String = "Privacy_Microphone") {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 会議アプリの音の録音（システムオーディオ録音）。「画面収録とシステムオーディオ録音」のペインにある。
    static func openSystemAudio() { openPrivacy(pane: "Privacy_ScreenCapture") }

    static func openNotifications() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 許可のエラーの文言から開くペインを選ぶ。会議アプリの音の失敗でマイクのペインを開かない。
    static func openPrivacy(forError message: String) {
        if message.contains("システムオーディオ") || message.contains("画面収録") {
            openSystemAudio()
        } else {
            openPrivacy()
        }
    }
}

// MARK: - ツールバー

/// セッション状態（待機中 / 録音中 …）。録音中はクリックで録音中の会議を表示する。
struct SessionStatusBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.sessionState
        Button {
            if let meeting = model.currentMeeting { model.selectedMeetingId = meeting.id }
        } label: {
            HStack(spacing: 6) {
                if state == .finalizing {
                    ProgressView().controlSize(.small)
                } else {
                    // 録音中の点滅・準備中の呼吸は `AnimatedSymbol` で描く（ツールバーはウィンドウを開いている間ずっと見えている）
                    AnimatedSymbol(
                        systemName: state.symbol,
                        pointSize: NSFont.systemFontSize,
                        color: state.tint,
                        effect: state == .recording ? .pulse : state == .armed ? .breathe : nil
                    )
                }
                Text(state == .recording ? "録音中 \(TimeFormatting.mmssShort(model.windowElapsedSeconds))" : state.title)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(state == .recording ? Palette.record : Color.secondary)
                    .id(state)
                    .transition(.blurReplace)
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: state)
        .help(model.currentMeeting.map { "録音中: \($0.title)（クリックで表示）" } ?? state.detail)
        .accessibilityValue(model.postProcessingSummary ?? "")
    }
}

/// 録音 / 停止。待機中は開始前の確認（タイトル・対象アプリ・プライバシー）を出し、準備中は「今すぐ開始」を出す。
struct RecordToolbarButton: View {
    @Environment(AppModel.self) private var model
    @State private var showingStart = false

    var body: some View {
        switch model.sessionState {
        case .armed:
            Button { model.startNow() } label: {
                Label(model.awaitingStartConfirmation ? "録音を開始" : "今すぐ開始", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.record)
            .help(model.awaitingStartConfirmation ? "会議の音声を検知しました。録音を開始します（⇧⌘R）" : "音声の検知を待たずに録音を開始（⇧⌘R）")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button { model.stopRecording() } label: { Label("キャンセル", systemImage: "xmark.circle") }
                .help("録音準備をキャンセル（⇧⌘.）")
        case .recording:
            Button { model.stopRecording() } label: { Label("停止", systemImage: "stop.fill") }
                .buttonStyle(.borderedProminent)
                .tint(Palette.record)
                .help("録音を停止（⇧⌘.）")
        case .finalizing:
            Button { model.stopRecording() } label: { Label("録音を終了", systemImage: "stop.fill") }
                .help("自動停止の猶予を待たずに録音を終了")
        default:
            Button { showingStart = true } label: {
                Label("録音", systemImage: "record.circle")
                    .foregroundStyle(Palette.record)
            }
            .disabled(model.isRecording)
            .help("録音を開始（⇧⌘R）")
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .popover(isPresented: $showingStart, arrowEdge: .bottom) {
                RecordStartPopover(isPresented: $showingStart)
            }
        }
    }
}

/// 録音開始前の確認: タイトル、カレンダーの予定、録音対象アプリ、プライバシー。
struct RecordStartPopover: View {
    @Environment(AppModel.self) private var model
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var candidateId: String?
    @State private var privacy: PrivacyMode = .cloudOk
    @State private var selectedApps: Set<String> = []
    @State private var runningApps: [(bundleID: String, name: String)] = []

    private var selectedCandidate: CalendarCandidate? { model.candidates.first { $0.id == candidateId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("録音を開始").font(.headline)
            if !model.candidates.isEmpty {
                Picker("予定", selection: $candidateId) {
                    Text("予定なし（手動）").tag(String?.none)
                    ForEach(model.candidates) { candidate in
                        Text("\(candidate.title)（\(Formatting.timeRange(candidate.startDate, candidate.endDate))）").tag(String?.some(candidate.id))
                    }
                }
                .onChange(of: candidateId) { _, _ in
                    if let candidate = selectedCandidate { title = candidate.title }
                }
            }
            TextField("タイトル", text: $title, prompt: Text(model.defaultTitle()))
                .textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                Text("録音対象アプリ").font(.caption).foregroundStyle(.secondary)
                if runningApps.isEmpty {
                    Label("対象アプリが起動していません。設定の対象アプリを起動してください。", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Palette.amber)
                } else {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Toggle(isOn: Binding(
                            get: { selectedApps.contains(app.bundleID) },
                            set: { on in if on { selectedApps.insert(app.bundleID) } else { selectedApps.remove(app.bundleID) } }
                        )) {
                            Text(app.name)
                        }
                    }
                }
            }
            Picker("プライバシー", selection: $privacy) {
                ForEach(PrivacyMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            HStack {
                Spacer()
                Button("キャンセル") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    start()
                } label: {
                    Label("録音を開始", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.record)
                .keyboardShortcut(.defaultAction)
                .disabled(runningApps.isEmpty || selectedApps.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            privacy = model.privacyModeForNextMeeting
            model.refreshCandidates()
            runningApps = model.runningTargetApps()
            selectedApps = Set(runningApps.map(\.bundleID))
            if let first = model.candidates.first, first.startDate <= Date().addingTimeInterval(600) {
                candidateId = first.id
                title = first.title
            }
        }
    }

    private func start() {
        var info: PendingMeetingInfo
        if let candidate = selectedCandidate {
            info = candidate.pendingInfo
        } else {
            info = PendingMeetingInfo(title: model.defaultTitle())
        }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty { info.title = cleaned }
        info.privacyMode = privacy
        info.targetBundleIdentifiers = Array(selectedApps)
        model.privacyModeForNextMeeting = privacy
        isPresented = false
        model.startRecording(info)
    }
}

// MARK: - サイドバー

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.selectedItem }, set: { if let item = $0 { model.select(item) } })) {
            Section("スマートフォルダ") {
                ForEach(SmartFolder.allCases) { folder in
                    Label(folder.title, systemImage: folder.systemImage).tag(SidebarItem.folder(folder))
                }
            }
            if !model.tags.isEmpty {
                Section("タグ") {
                    ForEach(model.tags) { entry in
                        Label {
                            HStack {
                                Text(entry.tag).lineLimit(1)
                                Spacer()
                                Text("\(entry.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "tag")
                        }
                        .tag(SidebarItem.tag(entry.tag))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "会議・本文・要約を検索")
        .onChange(of: model.searchText) { _, _ in model.runSearch() }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
    }
}

/// サイドバー下部: 次の会議候補とプロバイダの状態。
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = model.postProcessingSummary {
                Label(summary, systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("後処理中も次の会議を録音できます")
            }
            if let next = model.candidates.first, !model.isRecording {
                NextMeetingCard(candidate: next)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button {
                model.requestedSettingsTab = .providers
                openSettings()
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    ProviderStatusRow(symbol: "waveform.badge.magnifyingglass", title: "確定文字起こし", value: model.finalProviderLabel, ready: model.finalProviderReady)
                    ProviderStatusRow(symbol: "sparkles", title: "要約", value: model.summaryStatusLabel, ready: model.hasSummarizer || model.settings.resolvedSummaryProvider == .none)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Surface.card, in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(.rect(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help("設定を開く")
        }
        .padding(10)
        .animation(.smooth, value: model.candidates.first?.id)
    }
}

struct NextMeetingCard: View {
    @Environment(AppModel.self) private var model
    let candidate: CalendarCandidate

    var body: some View {
        HStack(spacing: 10) {
            PlatformIcon(platform: candidate.platform, size: 28, tint: Palette.color(forKey: candidate.title))
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.startDate <= Date() ? "進行中の会議" : "次の会議")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(candidate.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(Formatting.timeRange(candidate.startDate, candidate.endDate))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                var info = candidate.pendingInfo
                info.privacyMode = model.privacyModeForNextMeeting
                model.startRecording(info)
            } label: {
                PillGlyph(kind: .record, size: 24)
            }
            .buttonStyle(GlyphButtonStyle())
            .help("この会議として録音を開始（プライバシー: \(model.privacyModeForNextMeeting.title)）")
        }
        .padding(10)
        .background(Surface.card, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

struct ProviderStatusRow: View {
    let symbol: String
    let title: String
    let value: String
    let ready: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption).lineLimit(1)
            }
            Spacer(minLength: 4)
            Circle()
                .fill(ready ? Palette.mint : Palette.amber)
                .frame(width: 7, height: 7)
                .help(ready ? "利用できます" : "設定が必要です")
        }
    }
}

// MARK: - 中央カラム

struct ContentColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.isSearchActive {
                SearchResultsView().transition(.opacity)
            } else {
                MeetingListView().transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: model.isSearchActive)
        .navigationSplitViewColumnWidth(min: 290, ideal: 350)
    }
}

struct MeetingListView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: MeetingRecord?
    @State private var confirmingDelete = false

    private struct DayGroup: Identifiable {
        let day: Date
        let title: String
        let meetings: [MeetingRecord]
        var id: Date { day }
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.meetings) { calendar.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(day: day, title: Formatting.dayTitle(day), meetings: (grouped[day] ?? []).sorted { $0.startedAt > $1.startedAt })
        }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMeetingId) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            isLive: model.isRecording && model.currentMeeting?.id == meeting.id,
                            sessionState: model.currentMeeting?.id == meeting.id ? model.sessionState : nil,
                            preview: model.meetingPreviews[meeting.id]
                        )
                        .tag(meeting.id)
                        .contextMenu { contextMenu(for: meeting) }
                    }
                } header: {
                    Text(group.title).listHeaderSeparatorHidden()
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.meetings)
        .navigationTitle(model.selectedItem.title)
        .onDeleteCommand {
            guard let id = model.selectedMeetingId, let meeting = model.meeting(id: id), model.canDeleteMeeting(meeting) else { return }
            pendingDelete = meeting
            confirmingDelete = true
        }
        .overlay {
            if model.meetings.isEmpty { emptyState }
        }
        .confirmationDialog("この会議を削除しますか？", isPresented: $confirmingDelete, presenting: pendingDelete) { meeting in
            Button("削除", role: .destructive) { model.deleteMeeting(meeting) }
                .disabled(!model.canDeleteMeeting(meeting))
            Button("キャンセル", role: .cancel) {}
        } message: { meeting in
            Text("「\(meeting.title)」の文字起こし・要約・音声を削除します。この操作は取り消せません。")
        }
    }

    @ViewBuilder
    private func contextMenu(for meeting: MeetingRecord) -> some View {
        if meeting.privacy == .cloudOk {
            Button {
                ExportFolderOpener.open(meeting: meeting, exportDirectory: model.settings.exportDirectoryURL)
            } label: {
                Label("書き出しフォルダを開く", systemImage: "folder")
            }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("minutes://meeting/\(meeting.id)", forType: .string)
        } label: {
            Label("リンクをコピー", systemImage: "link")
        }
        if meeting.meetingStatus == .failed {
            Button {
                model.retryPipeline(meetingId: meeting.id)
            } label: {
                Label("後処理をやり直す", systemImage: "arrow.clockwise")
            }
        }
        Divider()
        if !model.tags.isEmpty {
            Menu {
                ForEach(model.tags) { entry in
                    Button {
                        model.toggleTag(entry.tag, for: meeting)
                    } label: {
                        if meeting.tags.contains(entry.tag) { Label(entry.tag, systemImage: "checkmark") } else { Text(entry.tag) }
                    }
                }
            } label: {
                Label("タグ", systemImage: "tag")
            }
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = meeting
            confirmingDelete = true
        } label: {
            Label("削除…", systemImage: "trash")
        }
        .disabled(!model.canDeleteMeeting(meeting))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: model.selectedItem.systemImage)
        } description: {
            Text(emptyDescription)
        } actions: {
            if let folder = model.selectedItem.folder, folder == .today || folder == .thisWeek || folder == .all, !model.isRecording {
                Button {
                    model.startRecording()
                } label: {
                    Label("録音を開始", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var emptyTitle: String {
        switch model.selectedItem {
        case .folder(.today): "今日の会議はありません"
        case .folder(.thisWeek): "今週の会議はありません"
        case .folder(.all): "会議がありません"
        case .folder(.unprocessed): "処理中の会議はありません"
        case .folder(.failed): "失敗した会議はありません"
        case let .tag(tag): "「\(tag)」の会議はありません"
        }
    }

    private var emptyDescription: String {
        switch model.selectedItem {
        case .folder(.unprocessed): "録音が終わった会議はここに表示され、文字起こしと要約が完了すると消えます。"
        case .folder(.failed): "録音や後処理に失敗した会議はここに残り、やり直しできます。"
        case .tag: "会議の詳細や右クリックメニューでタグを付けると、ここに並びます。"
        default: "会議アプリで会議を開き、録音を開始すると議事録がここに並びます。"
        }
    }
}

/// 書き出しフォルダは会議ごと。まだ書き出していなければ親フォルダを開く。
enum ExportFolderOpener {
    static func open(meeting: MeetingRecord, exportDirectory: URL) {
        let folder = exportDirectory.appendingPathComponent(MeetingExporter.folderName(meeting: meeting), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        } else {
            NSWorkspace.shared.open(exportDirectory)
        }
    }
}

struct MeetingRow: View {
    let meeting: MeetingRecord
    var isLive = false
    /// この会議が現在のセッションなら、その状態（armed を「準備中」と出すため）。
    var sessionState: SessionState?
    var preview: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PlatformIcon(platform: meeting.meetingPlatform, size: 34, isLive: isLive, tint: Palette.color(for: meeting))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(meeting.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if meeting.privacy == .localOnly {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("ローカルのみ（クラウドへ送信しない）")
                    }
                    if sessionState == .armed {
                        StatusPill(status: .recording, titleOverride: "準備中", tintOverride: Palette.amber, symbolOverride: "waveform.badge.magnifyingglass")
                    } else if meeting.meetingStatus != .done {
                        StatusPill(status: meeting.meetingStatus)
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let preview, !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !meeting.attendees.isEmpty {
                    HStack(spacing: 6) {
                        HStack(spacing: -4) {
                            ForEach(meeting.attendees.prefix(4), id: \.self) { attendee in
                                AvatarView(name: attendee.name, size: 16)
                                    .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                            }
                        }
                        Text(meeting.attendees.map(\.name).joined(separator: "、"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var line = Formatting.timeRange(meeting.startedAt, meeting.endedAt)
        if let end = meeting.endedAt { line += " · " + Formatting.duration(end.timeIntervalSince(meeting.startedAt)) }
        if !meeting.attendees.isEmpty, preview != nil { line += " · " + meeting.attendees.map(\.name).prefix(3).joined(separator: "、") }
        if !meeting.tags.isEmpty { line += " · " + meeting.tags.prefix(3).map { "#" + $0 }.joined(separator: " ") }
        return line
    }
}

// MARK: - 検索結果

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    private var hitCount: Int { model.searchResults.reduce(0) { $0 + $1.segmentHits.count + ($1.notesMatched ? 1 : 0) + ($1.titleMatched ? 1 : 0) } }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedMeetingId) {
            ForEach(model.searchResults, id: \.meeting.id) { result in
                Section {
                    if result.titleMatched {
                        Label("タイトル・参加者にヒット", systemImage: "textformat")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .tag(result.meeting.id)
                    }
                    ForEach(result.segmentHits, id: \.segment.id) { hit in
                        SearchHitRow(hit: hit, query: model.searchText)
                            .tag(result.meeting.id)
                            .simultaneousGesture(TapGesture().onEnded { model.pendingSegmentId = hit.segment.id })
                    }
                    if result.notesMatched {
                        Label("要約・メモにヒット", systemImage: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .tag(result.meeting.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(result.meeting.title).lineLimit(1)
                        Spacer()
                        Text(result.meeting.startedAt.formatted(date: .abbreviated, time: .omitted))
                            .foregroundStyle(.secondary)
                    }
                    .listHeaderSeparatorHidden()
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: model.searchResults)
        .navigationTitle("検索")
        .navigationSubtitle(model.isSearching ? "検索中…" : "“\(model.searchText)” \(hitCount) 件")
        .overlay {
            if model.searchResults.isEmpty, !model.isSearching {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

struct SearchHitRow: View {
    let hit: SearchHit
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(hit.context, id: \.id) { segment in
                let isHit = segment.id == hit.segment.id
                HighlightedText(text: segment.text, query: query, emphasized: isHit)
                    .font(isHit ? .body : .caption)
                    .foregroundStyle(isHit ? .primary : .secondary)
                    .lineLimit(isHit ? 4 : 1)
            }
            Text(TimeFormatting.hms(hit.segment.tStart))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

/// 検索語をハイライトする（大文字小文字を無視）。
struct HighlightedText: View {
    let text: String
    let query: String
    var emphasized = false

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return result }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, options: .caseInsensitive, range: searchRange) {
            if let lower = AttributedString.Index(range.lowerBound, within: result), let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].backgroundColor = .yellow.opacity(0.4)
                if emphasized { result[lower..<upper].font = .body.bold() }
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return result
    }
}

// MARK: - 右カラム

struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    private enum Mode: Equatable {
        case recording
        case meeting(String)
        case empty

        /// 表示の種類。会議どうしの切り替えは同じ種類として扱う。
        var kind: Int {
            switch self {
            case .recording: 0
            case .meeting: 1
            case .empty: 2
            }
        }

        var isMeeting: Bool {
            if case .meeting = self { true } else { false }
        }
    }

    /// 選択中の会議が録音中の会議なら録音ビュー。何も選んでいなければ、録音中に限り録音ビュー。
    private var mode: Mode {
        if let id = model.selectedMeetingId {
            if model.isRecording, model.currentMeeting?.id == id { return .recording }
            return .meeting(id)
        }
        if model.isRecording { return .recording }
        return .empty
    }

    var body: some View {
        Group {
            switch mode {
            case .recording:
                RecordingView(meeting: model.currentMeeting)
            case .meeting(let id):
                MeetingDetailView(meetingId: id)
                    .id(id)
            case .empty:
                EmptyDetailView()
            }
        }
        // 切り替えはトランジションにしない（アニメーション中は前の表示が残り、前後の内容が重なる）。
        // 会議どうしは即座に差し替え、空 / 会議 / 録音が変わるときだけ新しい表示を短くフェードインする。
        .modifier(FadeInOnAppear())
        .id(mode.kind)
        // 会議を出していないときはツールバーの「⋯」を消す（会議を出しているときは詳細画面が状態を渡す）
        .onChange(of: mode.isMeeting, initial: true) { _, isMeeting in
            if !isMeeting { model.meetingActions = nil }
        }
    }
}

/// 表示されたときにフェードインする。前の表示はすぐに外れるので、トランジションと違って前後の内容が重ならない。
private struct FadeInOnAppear: ViewModifier {
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onAppear { withAnimation(.easeOut(duration: 0.18)) { visible = true } }
    }
}

/// 何も選んでいないときの右ペイン。ウィンドウの中でブランドを見せるのはここだけにする（会議を選ぶと消えるので作業の邪魔にならない）。
struct EmptyDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("会議を選択")
            } icon: {
                Image(nsImage: BrandAssets.mark)
                    .resizable()
                    .renderingMode(.template)
                    .interpolation(.high)
                    .scaledToFit()
                    // 色は付けず、隣の列の空の表示の記号と同じ灰色にする（この画面で色を持つのは録音ボタンだけにする）。
                    // 塗りの形は線の記号より重く見えるので、隣の列の空の表示の記号より少し小さく描く。
                    // 占める高さは記号と同じにして、2 列とも空のときに見出しの高さをそろえる
                    .frame(height: 34)
                    .frame(height: 40)
                    .accessibilityHidden(true)
            }
        } description: {
            Text("左のリストから会議を選ぶか、録音を開始してください。\n録音中はここにライブ字幕とメモが表示されます。")
        } actions: {
            Button {
                model.startRecording()
            } label: {
                Label("録音を開始", systemImage: "record.circle")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.record)
            .controlSize(.large)
            .disabled(model.isRecording)
        }
    }
}
