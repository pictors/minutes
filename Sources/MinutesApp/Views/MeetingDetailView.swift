import AppKit
import MinutesCore
import SwiftUI

/// 議事録ビュー（SPEC §10.2 右ペイン）: 要約 → 決定事項 → アクション → 未決 → メモ → 全文。
/// データと操作は `MeetingDetailModel` が持ち、DB の変更（後処理の完了・CLI の再処理）は監視で反映される。
struct MeetingDetailView: View {
    @Environment(AppModel.self) private var model
    let meetingId: String
    @State private var detail: MeetingDetailModel?

    var body: some View {
        Group {
            if let detail {
                MeetingDetailContent(detail: detail)
            } else {
                Color.clear
            }
        }
        // onAppear は最初のフレームの描画より前に終わるので、読み込み中の表示を挟まずに内容を出せる。監視は .task で続ける。
        .onAppear(perform: load)
        .task(id: meetingId) {
            load()
            await detail?.observe()
        }
    }

    private func load() {
        guard detail?.meetingId != meetingId, let created = model.makeDetailModel(meetingId: meetingId) else { return }
        created.reload()
        detail = created
        if let meeting = created.meeting { model.playback.load(meeting: meeting) }
    }
}

/// 話者のポップオーバー。吹き出しはクリックした場所（話者カードの行・発話の話者チップ）から出す。
private struct SpeakerPopover: Identifiable {
    enum Anchor: Hashable {
        /// 話者カードの行（speaker id）
        case speakerRow(String)
        /// 全文の発話（segment id）
        case segment(Int64)
    }

    enum Kind {
        /// 同じ話者の発言すべてに割り当てる
        case assign(SpeakerRecord)
        /// この発話だけに名前を付ける
        case name(segmentId: Int64)
    }

    let anchor: Anchor
    let kind: Kind
    var id: Anchor { anchor }
}

/// 会議詳細の「組み替え」を伴う状態。後処理の進行、要約・バナーの有無、アクション・タグ・参加者の増減。
/// これが変わったときだけ詳細全体を `Motion.layout` で動かし、本文の編集や話者の割当（瞬時に揃うことに意味がある）は動かさない。
private struct DetailPhase: Equatable {
    var jobStatus: PostProcessingStatus?
    var meetingStatus: MeetingStatus?
    var source: SegmentSource
    var summary: String?
    var isSummarizing: Bool
    var summaryStale: Bool
    var warnings: [String]
    var provider: String?
    var resolutionNote: String?
    var audioPurged: Bool
    var hasError: Bool
    var hasNotesError: Bool
    var actionIds: [String]
    var tags: [String]
    var attendees: [String]
}

/// アクションの行。識別子は保存時に採番された ID で、ない（古い要約の）ものだけ位置で代用する。
/// 位置だけで識別すると、削除のたびに後続の行がすべて別物になって動いてしまう。
private struct IndexedAction: Identifiable {
    let index: Int
    let action: MinutesSummary.ActionItem
    var id: String { action.id ?? "#\(index)" }
}

struct MeetingDetailContent: View {
    @Environment(AppModel.self) private var model
    let detail: MeetingDetailModel

    /// 要約を作れるか。会議の状態に加え、要約の手段があるか（「要約しない」やキーのない Anthropic では作れない）。
    private var canSummarize: Bool { detail.canSummarize && model.hasSummarizer }

    @State private var editingSegmentId: Int64?
    @State private var editText = ""
    @State private var speakerPopover: SpeakerPopover?
    @State private var highlightedSegmentId: Int64?
    @State private var extraSegments: [SegmentRecord] = []
    @State private var confirmingDelete = false
    @State private var pendingPrivacy: PrivacyMode?
    /// 文字起こしし直す前の確認を出している言語。
    @State private var pendingLanguage: MeetingLanguage?
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @State private var newActionText = ""
    @State private var followPlayback = true
    @State private var currentSegmentId: Int64?
    @State private var editingAttendees = false
    /// 背景の声として除外した話者の発話を全文に出す（既定は折りたたむ）。
    @State private var showsExcluded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var notesDraft: UserNotesDraft { detail.notesDraft }
    private var selfName: String { model.selfDisplayName }

    /// 表示する発話（旧世代の根拠へジャンプしたときはその発話も含める）。背景の声として除外した話者の発話は、開いたときだけ出す。
    private var displayedSegments: [SegmentRecord] {
        var segments = detail.segments
        if !extraSegments.isEmpty {
            let ids = Set(detail.segments.compactMap(\.id))
            segments = (segments + extraSegments.filter { $0.id.map { !ids.contains($0) } ?? false }).sorted { $0.tStart < $1.tStart }
        }
        guard !showsExcluded else { return segments }
        return segments.filter { !detail.isExcluded($0) }
    }

    /// 組み替えを伴う状態（後処理の進行、要約・バナーの有無、アクション・タグ・参加者の増減）。
    private var phase: DetailPhase {
        DetailPhase(
            jobStatus: detail.job?.jobStatus,
            meetingStatus: detail.meeting?.meetingStatus,
            source: detail.source,
            summary: detail.notes?.summaryMd,
            isSummarizing: detail.isSummarizing,
            summaryStale: detail.summaryStale,
            warnings: detail.pendingWarnings.map(\.id),
            provider: detail.finalProviderName,
            resolutionNote: resolutionNote,
            audioPurged: detail.audioPurged,
            hasError: detail.error != nil,
            hasNotesError: notesDraft.saveError != nil,
            actionIds: indexedActions.map(\.id),
            tags: detail.meeting?.tags ?? [],
            attendees: detail.meeting?.attendees.map(\.name) ?? []
        )
    }

    /// 話者の解決で「編集済み…」の注記があれば出す（バナー）。
    private var resolutionNote: String? {
        guard let resolution = detail.runs.last(where: { $0.step == PipelineStep.resolveSpeakers.rawValue && $0.runStatus == .ok }),
              let message = resolution.provider, message.hasPrefix("編集済み") else { return nil }
        return message
    }

    private var indexedActions: [IndexedAction] {
        (detail.notes?.actionItems ?? []).enumerated().map { IndexedAction(index: $0.offset, action: $0.element) }
    }

    var body: some View {
        Group {
            if let meeting = detail.meeting {
                content(meeting)
            } else {
                ContentUnavailableView("会議が見つかりません", systemImage: "questionmark.folder", description: Text("削除されたか、別のデータベースの会議です。"))
            }
        }
        // ウィンドウのツールバーの「⋯」へ状態と操作の対象を渡す。状態が同じ会議どうしなら値は変わらず、ツールバーも作り直されない。
        .onChange(of: actionsState, initial: true) { _, state in model.meetingActions = state }
        .onAppear {
            model.meetingActionsTarget = MeetingActionsTarget(
                detail: detail,
                rename: { if let meeting = detail.meeting { beginTitleEdit(meeting) } },
                requestDelete: { confirmingDelete = true }
            )
        }
        .onDisappear {
            if model.meetingActionsTarget?.detail === detail { model.meetingActionsTarget = nil }
        }
    }

    /// 「⋯」の項目を決める状態（会議がなければ「⋯」を出さない）。
    private var actionsState: MeetingActionsState? {
        guard let meeting = detail.meeting else { return nil }
        return MeetingActionsState(
            canSummarize: canSummarize,
            isSummarizing: detail.isSummarizing,
            isExporting: detail.isExporting,
            isFailed: meeting.meetingStatus == .failed,
            isCloudOk: meeting.privacy == .cloudOk,
            isDone: meeting.meetingStatus == .done,
            canDelete: model.canDeleteMeeting(meeting)
        )
    }

    private func content(_ meeting: MeetingRecord) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(meeting)
                    banners(meeting)
                    summaryCard(meeting)
                    decisionsCard
                    actionsCard
                    questionsCard
                    notesCard
                    speakersCard(meeting)
                    transcriptCard(meeting)
                        // 全文は数百行になるので組み替えの動きから外す（行が一斉にフェードすると重い）。カード自体の位置は親に従って動く
                        .transaction { $0.animation = nil }
                }
                .padding(20)
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                // 組み替え（後処理の完了、バナー、行やチップの増減）だけを動かす。会議の切り替えや本文の編集・話者の割当は動かさない
                .animation(Motion.layout, value: phase)
            }
            // 音声は会議を開いた直後に裏で読み込まれる。切り替えのたびに動かないよう、再生バーは出すだけにする。
            .safeAreaBar(edge: .bottom) {
                if model.playback.isAvailable {
                    PlaybackBar(follow: $followPlayback)
                }
            }
            .onChange(of: highlightedSegmentId) { _, id in
                if let id { withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: model.playback.currentTime) { _, time in
                let id = detail.segmentId(at: time)
                guard id != currentSegmentId else { return }
                currentSegmentId = id
                guard followPlayback, model.playback.isPlaying, let id else { return }
                // 発話が変わるたびに飛ばず、読んでいる行を目で追えるように滑らせる（根拠へのジャンプと同じ曲線。Reduce Motion では即時）
                if reduceMotion {
                    proxy.scrollTo(id, anchor: .center)
                } else {
                    withAnimation(Motion.follow) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .onChange(of: model.pendingSegmentId) { _, id in
                if let id { jump(to: Int(id)); model.pendingSegmentId = nil }
            }
            .onAppear {
                if let pending = model.pendingSegmentId { jump(to: Int(pending)); model.pendingSegmentId = nil }
            }
        }
        // 見出し（navigationTitle / Subtitle）は付けない。画面には出ない（ウィンドウのタイトルは中央カラム）のに、
        // 会議を切り替えるたびにツールバーの配置をやり直させて切り替えが遅くなる。
        .onDisappear { notesDraft.flush() }
        .confirmationDialog("この会議を削除しますか？", isPresented: $confirmingDelete) {
            Button("削除", role: .destructive) { model.deleteMeeting(meeting) }
                .disabled(detail.isSummarizing || detail.isExporting || !model.canDeleteMeeting(meeting))
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("「\(meeting.title)」の文字起こし・要約・音声を削除します。この操作は取り消せません。")
        }
        .confirmationDialog(privacyDialogTitle, isPresented: Binding(get: { pendingPrivacy != nil }, set: { if !$0 { pendingPrivacy = nil } }), titleVisibility: .visible) {
            if pendingPrivacy == .cloudOk {
                Button("送信して要約する") { detail.setPrivacy(.cloudOk); pendingPrivacy = nil }
            } else {
                Button("書き出し済みファイルも削除", role: .destructive) { detail.setPrivacy(.localOnly, removeExports: true); pendingPrivacy = nil }
                Button("ファイルは残す") { detail.setPrivacy(.localOnly, removeExports: false); pendingPrivacy = nil }
            }
            Button("キャンセル", role: .cancel) { pendingPrivacy = nil }
        } message: {
            Text(privacyDialogMessage)
        }
        .confirmationDialog(pendingLanguage.map { "\($0.title)で文字起こしし直しますか？" } ?? "", isPresented: Binding(get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } }), titleVisibility: .visible) {
            Button("文字起こしし直す") {
                if let language = pendingLanguage, detail.setLanguage(language) { model.retryPipeline(meetingId: meeting.id, reprocess: true) }
                pendingLanguage = nil
            }
            Button("キャンセル", role: .cancel) { pendingLanguage = nil }
        } message: {
            Text(languageDialogMessage(meeting))
        }
    }

    private func languageDialogMessage(_ meeting: MeetingRecord) -> String {
        var lines: [String] = []
        if meeting.privacy == .cloudOk, model.settings.finalProviderId != "local.speechanalyzer+fluidaudio" {
            lines.append("保存した音声を、もう一度文字起こしのサービスに送ります。")
        } else {
            lines.append("この Mac の中で文字起こしし直します。")
        }
        if meeting.privacy == .cloudOk, model.hasSummarizer { lines.append("要約も作り直します。") }
        if detail.hasTranscriptEdits { lines.append("本文の編集は外れます（編集した本文は履歴に残ります）。") }
        return lines.joined()
    }

    /// 会議の言語と要約の言語（ヘッダーのメニュー）。会議の言語を変えると文字起こしからやり直し、要約の言語を変えると要約だけを作り直す。
    private func languageMenu(_ meeting: MeetingRecord) -> some View {
        let language = meeting.meetingLanguage
        let summary = meeting.summaryOutputLanguage
        let canResummarize = detail.canSummarize && model.hasSummarizer && !detail.isSummarizing
        return Menu {
            Section("会議の言語") {
                ForEach(MeetingLanguage.allCases, id: \.self) { option in
                    Button {
                        // 同じ言語を選んだら確定させるだけ（文字起こしし直さない）
                        if option != language { pendingLanguage = option } else if meeting.languageDetected || meeting.language == nil { detail.confirmLanguage(option) }
                    } label: {
                        checkLabel(option.title, selected: meeting.language != nil && option == language)
                    }
                    .disabled(!detail.canChangeLanguage)
                }
            }
            Section("要約の言語") {
                ForEach(MeetingLanguage.allCases, id: \.self) { option in
                    Button { detail.setSummaryLanguage(option) } label: {
                        checkLabel(option.title, selected: option == summary)
                    }
                    .disabled(!canResummarize)
                }
            }
            if detail.audioPurged {
                Text("音声が削除済みのため、文字起こしし直せません")
            }
        } label: {
            Label(languageLabel(meeting), systemImage: "globe")
        }
        .menuStyle(.button)
        .fixedSize()
        .help("会議の言語を変えると文字起こしからやり直します。要約の言語を変えると要約だけを作り直します")
    }

    private func languageLabel(_ meeting: MeetingRecord) -> String {
        // 自動の会議は、後処理で言語が決まるまで「自動」
        guard meeting.language != nil || meeting.meetingStatus == .done || meeting.meetingStatus == .failed else { return "自動" }
        var text = meeting.meetingLanguage.title + (meeting.languageDetected ? "（自動判定）" : "")
        if meeting.summaryOutputLanguage != meeting.meetingLanguage { text += " · 要約は\(meeting.summaryOutputLanguage.title)" }
        return text
    }

    private func checkLabel(_ title: String, selected: Bool) -> some View {
        Group {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var privacyDialogTitle: String {
        pendingPrivacy == .cloudOk ? "クラウド OK に切り替えますか？" : "ローカルのみに切り替えますか？"
    }

    private var privacyDialogMessage: String {
        if pendingPrivacy == .cloudOk {
            return model.hasSummarizer ? "本文を \(model.summaryLabel) に送信して要約を生成し、書き出し・同期を行います。" : "書き出し・同期を行います。"
        }
        return "以後クラウドへは送信しません。既に書き出し・同期したファイルをどうするか選んでください。"
    }

    // MARK: - ヘッダー

    private func header(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                PlatformIcon(platform: meeting.meetingPlatform, size: 44, tint: Palette.color(for: meeting))
                VStack(alignment: .leading, spacing: 4) {
                    if editingTitle {
                        TextField("タイトル", text: $titleDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.title2.weight(.bold))
                            .onSubmit { commitTitle() }
                            .onExitCommand { editingTitle = false }
                    } else {
                        HStack(spacing: 8) {
                            Text(meeting.title)
                                .font(.title2.weight(.bold))
                                .textSelection(.enabled)
                                .onTapGesture(count: 2) { beginTitleEdit(meeting) }
                            Button {
                                beginTitleEdit(meeting)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("タイトルを変更")
                        }
                    }
                    Text(Formatting.dateLine(meeting.startedAt, meeting.endedAt))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if meeting.meetingStatus != .done {
                    StatusPill(status: meeting.meetingStatus)
                }
            }
            FlowLayout(spacing: 6) {
                ForEach(meeting.attendees, id: \.self) { attendee in
                    AttendeeChip(name: attendee.name)
                        .transition(Motion.chip(reduceMotion: reduceMotion))
                }
                Button {
                    editingAttendees = true
                } label: {
                    Label(meeting.attendees.isEmpty ? "参加者を追加" : "参加者を編集", systemImage: "person.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("参加者は話者の候補・文字起こしの用語・書き出しに使われます")
                .popover(isPresented: $editingAttendees, arrowEdge: .bottom) {
                    AttendeesEditor(attendees: meeting.attendees) { updated in
                        detail.updateAttendees(updated)
                        editingAttendees = false
                    }
                }
            }
            TagsRow(tags: meeting.tags, suggestions: model.tags.map(\.tag), onAdd: { detail.addTag($0) }, onRemove: { detail.removeTag($0) })
            HStack(spacing: 8) {
                Picker("プライバシー", selection: Binding(get: { meeting.privacy }, set: { mode in if mode != meeting.privacy { pendingPrivacy = mode } })) {
                    ForEach(PrivacyMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("ローカルのみにするとクラウドへ送信せず、書き出し・同期も行いません")
                languageMenu(meeting)
                if let provider = detail.finalProviderName {
                    InfoChip(text: "文字起こし: \(ProviderCatalog.summarizeRunProvider(provider))", systemImage: "waveform")
                        .help(provider)
                }
                if let summaryModel = detail.notes?.model, detail.notes?.summaryMd != nil {
                    InfoChip(text: "要約: \(ProviderCatalog.summarizeModel(summaryModel))", systemImage: "sparkles")
                        .help(summaryModel)
                }
                if detail.audioPurged {
                    InfoChip(text: "音声は保持期間を過ぎたため削除済み", systemImage: "speaker.slash")
                        .help("文字起こしと要約は残っています。再生と再認識はできません")
                }
                Spacer()
                if meeting.meetingStatus == .failed {
                    Button {
                        model.retryPipeline(meetingId: meeting.id)
                    } label: {
                        Label("後処理をやり直す", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func beginTitleEdit(_ meeting: MeetingRecord) {
        titleDraft = meeting.title
        editingTitle = true
    }

    private func commitTitle() {
        editingTitle = false
        let cleaned = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != detail.meeting?.title else { return }
        detail.rename(cleaned)
    }

    /// バナーは録音ビュー・メニューバーと同じく上端から出し入れする（`phase` の変化に合わせて動く）。
    @ViewBuilder
    private func banners(_ meeting: MeetingRecord) -> some View {
        Group {
            if let job = detail.job {
                switch job.jobStatus {
                case .queued, .running:
                    VStack(alignment: .leading, spacing: 8) {
                        Banner(kind: .info, text: job.jobStatus == .queued
                               ? "後処理の順番を待っています。次の会議は録音できます。"
                               : "保存した音声から文字起こし・要約を作成しています。次の会議は録音できます。")
                        StepProgressView(steps: detail.stepProgress)
                    }
                case .failed:
                    if let error = job.error {
                        Banner(kind: .error, text: "後処理に失敗しました: \(error)", actionTitle: "後処理をやり直す", action: { model.retryPipeline(meetingId: meeting.id) })
                    }
                }
            }
            if meeting.meetingStatus == .failed, detail.job?.jobStatus != .failed,
               let failed = detail.runs.last(where: { $0.runStatus == .failed }), let error = failed.error {
                let isCapture = failed.step == "capture"
                Banner(kind: .error, text: "\(isCapture ? "録音" : failed.step): \(error)",
                       actionTitle: isCapture ? nil : "後処理をやり直す",
                       action: { model.retryPipeline(meetingId: meeting.id) },
                       secondaryTitle: error.contains("許可") || error.contains("権限") ? "システム設定を開く" : nil,
                       secondaryAction: { SystemSettingsLink.openPrivacy(forError: error) })
            }
            // 要約をやり直している間は前回の失敗を出さない（進み具合は要約カードに出る。また失敗すれば新しい内容で出る）
            ForEach(detail.pendingWarnings.filter { $0.step != .summarize || !detail.isSummarizing }) { warning in
                Banner(kind: .warning, text: "\(warning.step.title)に失敗しました: \(warning.error ?? "")",
                       actionTitle: warning.step == .summarize ? (canSummarize ? "要約を生成" : nil) : "書き出しを更新",
                       action: { warning.step == .summarize ? detail.regenerateSummary() : detail.refreshExport() })
            }
            if detail.summaryStale, canSummarize, !detail.isSummarizing {
                Banner(kind: .info, text: "本文や話者が変わっています。要約は変更前の内容です。", actionTitle: "要約を更新", action: { detail.regenerateSummary() })
            }
            if let message = resolutionNote {
                Banner(kind: .info, text: message)
            }
            if let error = detail.error {
                Banner(kind: .error, text: error, secondaryTitle: "閉じる", secondaryAction: { detail.error = nil })
            }
            if let error = notesDraft.saveError {
                Banner(kind: .error, text: error, actionTitle: "メモを再保存", action: { notesDraft.flush() })
            }
        }
        .transition(Motion.banner(reduceMotion: reduceMotion))
    }

    // MARK: - カード

    private var noSummaryText: String {
        switch model.settings.resolvedSummaryProvider {
        case .none: "要約しない設定です。設定 > プロバイダ で要約の手段を選ぶと生成できます。"
        case .anthropic where !model.hasSummarizer: "要約の API キーが未設定です。設定 > プロバイダ で登録すると生成できます。"
        default: "要約はまだありません。"
        }
    }

    private func summaryCard(_ meeting: MeetingRecord) -> some View {
        SectionCard("要約", systemImage: "text.alignleft") {
            if let summary = detail.notes?.summaryMd, !summary.isEmpty {
                MarkdownBlocks(text: summary)
                    // 生成・更新で本文が変わったら、新しい本文として出す（古い本文は残さない）
                    .id(summary)
                    .transition(Motion.content(reduceMotion: reduceMotion))
            } else if detail.isSummarizing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("要約を生成しています…").foregroundStyle(.secondary)
                }
                .transition(Motion.placeholder)
            } else {
                Text(meeting.privacy == .localOnly
                     ? "ローカルのみの会議のため要約はありません。クラウド OK に切り替えると生成します。"
                     : (detail.isProcessing ? "後処理が終わると要約が表示されます。" : noSummaryText))
                    .foregroundStyle(.secondary)
                    .transition(Motion.placeholder)
            }
        } trailing: {
            if canSummarize {
                Button {
                    detail.regenerateSummary()
                } label: {
                    if detail.isSummarizing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("要約中…")
                        }
                    } else {
                        Label(detail.notes?.summaryMd == nil ? "生成" : "更新", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(detail.isSummarizing)
                .animation(.snappy, value: detail.isSummarizing)
            }
        }
    }

    private var decisionsCard: some View {
        let decisions = detail.notes?.decisions ?? []
        return SectionCard("決定事項", systemImage: "checkmark.seal", count: decisions.count) {
            if decisions.isEmpty { EmptyRow(text: "決定事項はありません").transition(Motion.placeholder) }
            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                EvidenceRow(text: decision.text, evidence: decision.evidence, tint: Palette.mint, resolve: resolveEvidence, onJump: jump)
                    .transition(Motion.content(reduceMotion: reduceMotion))
            }
        }
    }

    private var actionsCard: some View {
        let actions = indexedActions
        return SectionCard("アクション", systemImage: "checklist", count: actions.filter { !($0.action.done ?? false) }.count) {
            if actions.isEmpty { EmptyRow(text: "アクションはありません").transition(Motion.placeholder) }
            ForEach(actions) { item in
                let action = item.action
                ActionRow(action: action, selfName: selfName, onToggle: { detail.toggleAction(action, done: $0) }, resolve: resolveEvidence, onJump: jump)
                    .contextMenu {
                        if action.id != nil {
                            Button(role: .destructive) { detail.removeAction(action) } label: { Label("削除", systemImage: "trash") }
                        }
                    }
                    .transition(Motion.content(reduceMotion: reduceMotion))
            }
            HStack(spacing: 8) {
                TextField("アクションを追加（自分のタスク）", text: $newActionText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addAction)
                Button("追加", action: addAction)
                    .disabled(newActionText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func addAction() {
        let text = newActionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        detail.addAction(text: text)
        newActionText = ""
    }

    private var questionsCard: some View {
        let questions = detail.notes?.openQuestions ?? []
        return SectionCard("未決・論点", systemImage: "questionmark.bubble", count: questions.count) {
            if questions.isEmpty { EmptyRow(text: "未決の論点はありません").transition(Motion.placeholder) }
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                EvidenceRow(text: question.text, evidence: question.evidence, tint: Palette.amber, resolve: resolveEvidence, onJump: jump)
                    .transition(Motion.content(reduceMotion: reduceMotion))
            }
        }
    }

    private var notesCard: some View {
        SectionCard("メモ", systemImage: "note.text") {
            ZStack(alignment: .topLeading) {
                if notesDraft.text.isEmpty {
                    Text("会議の補足や自分用のメモを書けます")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { notesDraft.text }, set: { notesDraft.edit($0) }))
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 話者ごとの発言時間。行のクリックで話者を割り当てる（同じクラスタの発言すべてに反映）。
    /// 背景の声として除外した話者は下に薄く並べ、合計・割合・バーから外す。候補（ほかの話者より小さい声）の行には「除外」を出す。
    private func speakersCard(_ meeting: MeetingRecord) -> some View {
        let times = detail.talkTimes
        let active = times.filter { !isExcluded($0) }
        let excluded = times.filter { isExcluded($0) }
        let total = active.reduce(0) { $0 + $1.seconds }
        let candidates = detail.backgroundCandidates
        // 「除外」「戻す」の列。どれかの行にあれば、時間と割合の列がそろうよう全行で同じ幅を空ける
        let showsAccessory = !excluded.isEmpty || active.contains { $0.speaker.map { candidates[$0.id] != nil } ?? false }
        return SectionCard("話者", systemImage: "person.2.wave.2", count: active.count) {
            if times.isEmpty {
                EmptyRow(text: detail.isProcessing ? "文字起こしが終わると話者ごとの発言時間が表示されます" : "話者はまだいません")
                    .transition(Motion.placeholder)
            } else {
                Group {
                    StackedBar(segments: active.map { StackedBar.Segment(id: $0.id, value: $0.seconds, color: speakerColor($0)) })
                    VStack(spacing: 0) {
                        ForEach(active + excluded) { time in
                            speakerRow(time, total: total, meeting: meeting, candidateDelta: time.speaker.flatMap { candidates[$0.id] }, showsAccessory: showsAccessory)
                        }
                    }
                    .padding(.horizontal, -8)
                }
                .transition(Motion.content(reduceMotion: reduceMotion))
            }
        } trailing: {
            if total > 0 {
                Text(Formatting.duration(total))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("発言の合計（重なった発言は別々に数えます）")
            }
        }
    }

    private func speakerColor(_ time: MeetingDetailModel.TalkTime) -> Color {
        SpeakerPalette.color(for: time.speaker?.clusterLabel ?? time.clusterLabel)
    }

    private func isExcluded(_ time: MeetingDetailModel.TalkTime) -> Bool {
        time.speaker?.excluded ?? false
    }

    /// 話者の行の「除外」「戻す」の列の幅（小さいボタン 1 つと、割合との間）。
    private static let exclusionColumnWidth: CGFloat = 56

    @ViewBuilder
    private func speakerRow(_ time: MeetingDetailModel.TalkTime, total: Double, meeting: MeetingRecord, candidateDelta: Double?, showsAccessory: Bool) -> some View {
        let title = SpeakerNaming.title(for: time.speaker, clusterLabel: time.clusterLabel, selfName: selfName)
        let isMe = (time.speaker?.clusterLabel ?? time.clusterLabel) == TrackMerger.micSpeakerLabel
        let assignable = time.speaker.map { !$0.clusterLabel.hasPrefix("manual_") } ?? false
        let unassigned = assignable && !isMe && time.speaker?.displayName == nil
        let excluded = isExcluded(time)
        let anchor = SpeakerPopover.Anchor.speakerRow(time.id)
        let row = HStack(spacing: 0) {
            BreakdownRow(
                title: title,
                subtitle: speakerSubtitle(excluded: excluded, candidateDelta: candidateDelta, unassigned: unassigned),
                seconds: time.seconds,
                fraction: excluded || total <= 0 ? nil : time.seconds / total,
                reservesFractionColumn: excluded
            ) {
                SpeakerBadge(title: title, color: speakerColor(time))
            }
            .opacity(excluded ? 0.5 : 1)
            // 「除外」「戻す」は行のボタンの中に入れず、上に重ねる（ボタンの入れ子は押せない）。ここはその場所を空けるだけ
            if showsAccessory { Color.clear.frame(width: Self.exclusionColumnWidth, height: 1) }
        }
        .contentShape(.rect)
        Group {
            if let speaker = time.speaker, assignable {
                Button { speakerPopover = SpeakerPopover(anchor: anchor, kind: .assign(speaker)) } label: { row }
                    .buttonStyle(.plain)
                    .hoverHighlight(isActive: speakerPopover?.anchor == anchor)
                    .help(isMe ? "自分の声（マイク）。名前は設定で変更できます" : "クリックして話者を割り当て（同じ話者の発言すべてに反映）")
                    // 吹き出しは名前の下から、左端を行にそろえて出す（行の中央からでは何を指すか分かりにくく、印からでは会議リストにはみ出す）
                    .overlay(alignment: .leading) {
                        Color.clear
                            .frame(width: SpeakerAssignmentView.width)
                            .allowsHitTesting(false)
                            .popover(item: speakerPopoverBinding(anchor), arrowEdge: .bottom) { speakerPopoverContent($0, meeting: meeting) }
                    }
            } else {
                row
            }
        }
        .overlay(alignment: .trailing) {
            if showsAccessory, let speaker = time.speaker, excluded || candidateDelta != nil {
                exclusionButton(speaker, excluded: excluded)
                    .padding(.trailing, 8)
            }
        }
    }

    private func speakerSubtitle(excluded: Bool, candidateDelta: Double?, unassigned: Bool) -> String? {
        if excluded { return "背景の声として除外中" }
        if let candidateDelta { return "背景の声かもしれません（ほかの話者より \(Int((-candidateDelta).rounded())) dB 小さい）" }
        return unassigned ? "クリックして名前を割り当て" : nil
    }

    private func exclusionButton(_ speaker: SpeakerRecord, excluded: Bool) -> some View {
        Button(excluded ? "戻す" : "除外") {
            detail.setExcluded(speaker, excluded: !excluded)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(excluded
              ? "除外をやめて、本文・要約・書き出し・検索に戻します"
              : "背景の声として除外します。全文では折りたたみ、要約・書き出し・検索から外します（あとで戻せます）")
    }

    private func transcriptCard(_ meeting: MeetingRecord) -> some View {
        let segments = displayedSegments
        let excludedCount = detail.segments.reduce(0) { $0 + (detail.isExcluded($1) ? 1 : 0) }
        return SectionCard("全文", systemImage: "text.quote", count: segments.count) {
            if segments.isEmpty {
                EmptyRow(text: detail.isProcessing ? "文字起こしを作成しています" : (excludedCount > 0 ? "背景の声のほかに発言はありません" : "文字起こしはまだありません"))
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(segments) { segment in
                    TranscriptRow(
                        segment: segment,
                        highlighted: highlightedSegmentId == segment.id,
                        isPlaying: currentSegmentId != nil && currentSegmentId == segment.id && model.playback.isPlaying,
                        isEditing: editingSegmentId == segment.id,
                        isActive: segment.id.map { speakerPopover?.anchor == .segment($0) } ?? false,
                        isExcluded: showsExcluded && detail.isExcluded(segment),
                        editText: $editText,
                        onPlay: { model.playback.play(from: segment.tStart) },
                        onBeginEdit: { beginEdit(segment) },
                        onCommitEdit: { commitEdit(segment) },
                        onCancelEdit: { editingSegmentId = nil }
                    ) {
                        speakerChip(segment, meeting: meeting)
                    }
                    .id(segment.id ?? 0)
                    .contextMenu { segmentMenu(segment, meeting: meeting) }
                }
            }
        } trailing: {
            if excludedCount > 0 {
                Button {
                    showsExcluded.toggle()
                } label: {
                    Label(showsExcluded ? "背景の声を隠す" : "背景の声 \(excludedCount) 件を表示", systemImage: showsExcluded ? "eye.slash" : "eye")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("除外した話者の発言。要約・書き出し・検索には含めません")
            }
            InfoChip(
                text: detail.source == .final ? "確定" : "ライブ",
                systemImage: detail.source == .final ? "checkmark.seal.fill" : "dot.radiowaves.left.and.right",
                tint: detail.source == .final ? Palette.mint : Palette.amber
            )
        }
        // 話者を除外し直したら、全文はまた折りたたんだ状態から見せる
        .onChange(of: detail.speakers.filter(\.excluded).map(\.id)) { showsExcluded = false }
    }

    @ViewBuilder
    private func segmentMenu(_ segment: SegmentRecord, meeting: MeetingRecord) -> some View {
        Button { model.playback.play(from: segment.tStart) } label: { Label("ここから再生", systemImage: "play.fill") }
            .disabled(!model.playback.isAvailable)
        Button { beginEdit(segment) } label: { Label("本文を編集", systemImage: "pencil") }
        if let id = segment.id {
            Menu {
                ForEach(detail.speakers.filter { $0.displayName != nil || !$0.clusterLabel.hasPrefix("manual_") }) { speaker in
                    Button {
                        detail.overrideSpeaker(segmentId: id, speakerId: speaker.id)
                    } label: {
                        // 除外中の話者へ移すと、この発話も背景の声として外れる
                        let name = SpeakerNaming.title(for: speaker, clusterLabel: speaker.clusterLabel, selfName: selfName)
                        let title = speaker.excluded ? "\(name)（除外中）" : name
                        if segment.speakerId == speaker.id { Label(title, systemImage: "checkmark") } else { Text(title) }
                    }
                }
                Divider()
                Button { speakerPopover = SpeakerPopover(anchor: .segment(id), kind: .name(segmentId: id)) } label: { Label("新しい名前を付ける…", systemImage: "person.badge.plus") }
                if let cluster = segment.clusterLabel, let auto = detail.speakers.first(where: { $0.clusterLabel == cluster }), segment.speakerId != auto.id {
                    Button { detail.overrideSpeaker(segmentId: id, speakerId: nil) } label: { Label("自動割当に戻す", systemImage: "arrow.uturn.backward") }
                }
            } label: {
                Label("この発話の話者を変更", systemImage: "person.crop.circle")
            }
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("[\(TimeFormatting.hms(segment.tStart))] \(SpeakerNaming.title(for: detail.speaker(for: segment), clusterLabel: segment.clusterLabel, selfName: selfName)): \(segment.text)", forType: .string)
            } label: {
                Label("発話をコピー", systemImage: "doc.on.doc")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("minutes://meeting/\(meeting.id)?seg=\(id)", forType: .string)
            } label: {
                Label("この発話のリンクをコピー", systemImage: "link")
            }
        }
    }

    // MARK: - 話者のポップオーバー

    /// 発話の話者チップ。クリックで同じ話者の発言すべてに割り当てる（個別に名前を付けた発話は、その発話だけ名前を変える）。
    @ViewBuilder
    private func speakerChip(_ segment: SegmentRecord, meeting: MeetingRecord) -> some View {
        let speaker = detail.speaker(for: segment)
        let chip = SpeakerChip(
            title: SpeakerNaming.title(for: speaker, clusterLabel: segment.clusterLabel, selfName: selfName),
            color: SpeakerPalette.color(for: speaker?.clusterLabel ?? segment.clusterLabel)
        )
        if let id = segment.id {
            Button {
                if let speaker, !speaker.clusterLabel.hasPrefix("manual_") {
                    speakerPopover = SpeakerPopover(anchor: .segment(id), kind: .assign(speaker))
                } else {
                    speakerPopover = SpeakerPopover(anchor: .segment(id), kind: .name(segmentId: id))
                }
            } label: {
                chip
            }
            .buttonStyle(.plain)
            .help("クリックして話者を割り当て。右クリックでこの発話だけ変更")
            .popover(item: speakerPopoverBinding(.segment(id)), arrowEdge: .bottom) { speakerPopoverContent($0, meeting: meeting) }
        } else {
            chip
        }
    }

    /// その場所に出すポップオーバー。別の場所で開き直したとき、閉じる側が新しい状態を消さないようにする。
    private func speakerPopoverBinding(_ anchor: SpeakerPopover.Anchor) -> Binding<SpeakerPopover?> {
        Binding(
            get: { speakerPopover?.anchor == anchor ? speakerPopover : nil },
            set: { if $0 == nil, speakerPopover?.anchor == anchor { speakerPopover = nil } }
        )
    }

    @ViewBuilder
    private func speakerPopoverContent(_ popover: SpeakerPopover, meeting: MeetingRecord) -> some View {
        switch popover.kind {
        case .assign(let speaker):
            let onExclude: ((Bool) -> Void)? = BackgroundVoices.isRemoteCluster(speaker.clusterLabel) ? { excluded in
                detail.setExcluded(speaker, excluded: excluded)
                speakerPopover = nil
            } : nil
            SpeakerAssignmentView(meeting: meeting, speaker: speaker, selfName: selfName, onExclude: onExclude) { personId, name in
                detail.assign(speaker: speaker, personId: personId, name: name)
                speakerPopover = nil
            }
        case .name(let segmentId):
            SegmentNamingView(meeting: meeting) { name, email in
                detail.overrideSpeaker(segmentId: segmentId, personName: name, email: email)
                speakerPopover = nil
            }
        }
    }

    // MARK: - Data

    private func resolveEvidence(_ id: Int) -> EvidenceInfo? {
        guard let segment = detail.segment(id: Int64(id)) else { return nil }
        let speaker = SpeakerNaming.title(for: detail.speaker(for: segment), clusterLabel: segment.clusterLabel, selfName: selfName)
        return EvidenceInfo(id: id, time: TimeFormatting.hms(segment.tStart), speaker: speaker, text: segment.text)
    }

    private func jump(to segmentId: Int) {
        if !detail.segments.contains(where: { $0.id == Int64(segmentId) }), let previous = detail.segment(id: Int64(segmentId)) {
            extraSegments.append(previous)
        }
        // 背景の声として折りたたんだ発話（除外する前の要約の根拠など）は、開いてから移る
        if let target = detail.segment(id: Int64(segmentId)), detail.isExcluded(target) { showsExcluded = true }
        highlightedSegmentId = Int64(segmentId)
    }

    private func beginEdit(_ segment: SegmentRecord) {
        editingSegmentId = segment.id
        editText = segment.text
    }

    private func commitEdit(_ segment: SegmentRecord) {
        if let id = segment.id { detail.commitEdit(segmentId: id, text: editText) }
        editingSegmentId = nil
    }
}

// MARK: - 会議の操作（ツールバーの「⋯」）

/// 「⋯」の項目を決める状態。会議 ID を含めないので、状態が同じ会議どうしの切り替えではメニューを作り直さない。
struct MeetingActionsState: Equatable {
    var canSummarize: Bool
    var isSummarizing: Bool
    var isExporting: Bool
    var isFailed: Bool
    var isCloudOk: Bool
    var isDone: Bool
    var canDelete: Bool
}

/// 「⋯」の操作の対象。タイトルの変更と削除の確認は詳細画面の中の状態を使うので、詳細画面から受け取る。
struct MeetingActionsTarget {
    let detail: MeetingDetailModel
    let rename: () -> Void
    let requestDelete: () -> Void
}

/// 表示中の会議の操作。詳細画面ではなくウィンドウのツールバーに置き、項目は `state` が変わったときだけ作り直す
/// （詳細画面のツールバーに置くと、会議を切り替えるたびにメニューを作り直して 0.1 秒以上かかる）。対象は押したときに読む。
struct MeetingActionsMenu: View {
    @Environment(AppModel.self) private var model
    let state: MeetingActionsState

    private var target: MeetingActionsTarget? { model.meetingActionsTarget }

    var body: some View {
        Menu {
            if state.canSummarize {
                Button {
                    target?.detail.regenerateSummary()
                } label: {
                    Label(state.isSummarizing ? "要約中…" : "要約を生成・更新", systemImage: "sparkles")
                }
                .disabled(state.isSummarizing || state.isExporting)
            }
            if state.isFailed {
                Button {
                    if let target { model.retryPipeline(meetingId: target.detail.meetingId) }
                } label: {
                    Label("後処理をやり直す", systemImage: "arrow.clockwise")
                }
            }
            Button {
                target?.rename()
            } label: {
                Label("タイトルを変更", systemImage: "pencil")
            }
            Button {
                guard let target else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("minutes://meeting/\(target.detail.meetingId)", forType: .string)
            } label: {
                Label("この会議のリンクをコピー", systemImage: "link")
            }
            if state.isCloudOk {
                Button {
                    if let meeting = target?.detail.meeting {
                        ExportFolderOpener.open(meeting: meeting, exportDirectory: model.settings.exportDirectoryURL)
                    }
                } label: {
                    Label("書き出しフォルダを開く", systemImage: "folder")
                }
                if state.isDone {
                    Button {
                        target?.detail.refreshExport()
                    } label: {
                        Label(state.isExporting ? "書き出し中…" : "書き出し・同期を更新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(state.isExporting || state.isSummarizing)
                }
            }
            Divider()
            Button(role: .destructive) {
                target?.requestDelete()
            } label: {
                Label("削除…", systemImage: "trash")
            }
            .disabled(state.isSummarizing || state.isExporting || !state.canDelete)
        } label: {
            Label("操作", systemImage: "ellipsis.circle")
        }
        .help("この会議の操作")
    }
}

/// タグの表示・追加・削除（会議詳細のヘッダー）。既存タグは候補メニューから選べる。
struct TagsRow: View {
    let tags: [String]
    let suggestions: [String]
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    @State private var newTag = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var unusedSuggestions: [String] { suggestions.filter { !tags.contains($0) } }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Image(systemName: "tag").font(.caption2)
                    Text(tag).font(.caption).lineLimit(1)
                    Button { onRemove(tag) } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("タグを外す")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.fill.tertiary, in: .capsule)
                .transition(Motion.chip(reduceMotion: reduceMotion))
            }
            HStack(spacing: 4) {
                TextField("タグを追加", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(width: 110)
                    .onSubmit(submit)
                if !unusedSuggestions.isEmpty {
                    Menu {
                        ForEach(unusedSuggestions, id: \.self) { tag in
                            Button(tag) { onAdd(tag) }
                        }
                    } label: {
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("既存のタグから選ぶ")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.fill.quaternary, in: .capsule)
        }
    }

    private func submit() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        onAdd(tag)
        newTag = ""
    }
}

/// 参加者の編集（名前とメール）。登録済みの人物から追加もできる。
struct AttendeesEditor: View {
    private struct Row: Identifiable {
        let id = UUID()
        var name: String
        var email: String
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    @State private var people: [PersonRecord] = []
    let onSave: ([Attendee]) -> Void

    init(attendees: [Attendee], onSave: @escaping ([Attendee]) -> Void) {
        _rows = State(initialValue: attendees.map { Row(name: $0.name, email: $0.email ?? "") })
        self.onSave = onSave
    }

    private var unusedPeople: [PersonRecord] {
        let names = Set(rows.map { $0.name.trimmingCharacters(in: .whitespaces) })
        return people.filter { !names.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("参加者").font(.headline)
            if rows.isEmpty {
                Text("参加者はまだありません").font(.callout).foregroundStyle(.secondary)
            }
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField("名前", text: $row.name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    TextField("メール（任意）", text: $row.email)
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        rows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    rows.append(Row(name: "", email: ""))
                } label: {
                    Label("追加", systemImage: "plus")
                }
                if !unusedPeople.isEmpty {
                    Menu {
                        ForEach(unusedPeople) { person in
                            Button(person.name) { rows.append(Row(name: person.name, email: person.email ?? "")) }
                        }
                    } label: {
                        Label("登録済みから", systemImage: "person.crop.circle")
                    }
                    .fixedSize()
                }
            }
            Divider()
            HStack {
                Text("参加者名は次の文字起こしの用語と話者候補に使われます").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(rows.map { Attendee(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines), email: $0.email.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.email.trimmingCharacters(in: .whitespaces)) }.filter { !$0.name.isEmpty })
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
        .task { people = (try? model.store?.people()) ?? [] }
    }
}

/// 後処理のステップ表示（待機・実行中の会議）。記号の置き換えを状態の変化として見せる。
struct StepProgressView: View {
    let steps: [MeetingDetailModel.StepProgress]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 4) {
                    icon(step.status)
                        .frame(width: 14, height: 14)
                    Text(step.step.title)
                        .foregroundStyle(step.status == nil ? .tertiary : .secondary)
                }
                .font(.caption)
                .help(step.error ?? step.step.title)
                .animation(Motion.symbol, value: step.status)
            }
        }
        .padding(.horizontal, 4)
    }

    /// ○（未着手）/ スピナー（実行中）/ ✓（完了）/ 三角（失敗）。記号どうしは置き換えの効果で、スピナーとの入れ替えはフェード。
    @ViewBuilder
    private func icon(_ status: PipelineRunStatus?) -> some View {
        if status == .running {
            ProgressView().controlSize(.mini)
                .transition(.opacity)
        } else {
            Image(systemName: symbol(status))
                .foregroundStyle(tint(status))
                .contentTransition(.symbolEffect(.replace))
                .transition(.opacity)
        }
    }

    private func symbol(_ status: PipelineRunStatus?) -> String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "circle"
        }
    }

    private func tint(_ status: PipelineRunStatus?) -> AnyShapeStyle {
        switch status {
        case .ok: AnyShapeStyle(Palette.mint)
        case .failed: AnyShapeStyle(Palette.amber)
        default: AnyShapeStyle(.tertiary)
        }
    }
}

// MARK: - 再生バー（Liquid Glass、スクロール内容の上に浮かせる）

struct PlaybackBar: View {
    @Environment(AppModel.self) private var model
    @Binding var follow: Bool
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        let playback = model.playback
        let duration = max(playback.duration, 1)
        HStack(spacing: 10) {
            Button { playback.skip(by: -15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(.plain)
                .help("15 秒戻る")
            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "一時停止" : "再生")
            Button { playback.skip(by: 15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(.plain)
                .help("15 秒進む")
            Text(TimeFormatting.hms(scrubbing ? scrubValue : playback.currentTime))
                .font(.callout.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            Slider(
                value: Binding(get: { scrubbing ? scrubValue : playback.currentTime }, set: { scrubValue = $0 }),
                in: 0...duration
            ) { editing in
                scrubbing = editing
                if !editing { playback.seek(to: scrubValue) }
            }
            .controlSize(.small)
            Text(TimeFormatting.hms(playback.duration))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Menu {
                ForEach(AudioPlayback.rates, id: \.self) { rate in
                    Button {
                        playback.rate = rate
                    } label: {
                        if playback.rate == rate { Label(rateTitle(rate), systemImage: "checkmark") } else { Text(rateTitle(rate)) }
                    }
                }
            } label: {
                Text(rateTitle(playback.rate))
                    .font(.callout.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("再生速度")
            Toggle(isOn: $follow) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(follow ? Color.accentColor : Color.secondary)
            .help(follow ? "再生位置に追従してスクロール（オン）" : "再生位置に追従してスクロール（オフ）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 12)
    }

    private func rateTitle(_ rate: Float) -> String {
        rate == 1 ? "1×" : String(format: "%g×", rate)
    }
}

// MARK: - 行部品

struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
    }
}

/// 根拠リンクの表示情報（時刻・話者・本文の冒頭）。
struct EvidenceInfo {
    let id: Int
    let time: String
    let speaker: String
    let text: String
}

struct EvidenceRow: View {
    let text: String
    let evidence: [Int]
    var tint: Color = .secondary
    let resolve: (Int) -> EvidenceInfo?
    let onJump: (Int) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).textSelection(.enabled)
                EvidenceLinks(evidence: evidence, resolve: resolve, onJump: onJump)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 根拠のチップを折り返して並べる。
struct EvidenceLinks: View {
    let evidence: [Int]
    let resolve: (Int) -> EvidenceInfo?
    let onJump: (Int) -> Void

    var body: some View {
        if !evidence.isEmpty {
            FlowLayout(spacing: 4) {
                EvidenceChips(evidence: evidence, resolve: resolve, onJump: onJump)
            }
        }
    }
}

/// 根拠は DB の ID ではなく「時刻 話者」で示し、ホバーで本文の冒頭を出す。押せるチップなので、ホバー・押下で塗りが濃くなる
/// （担当・種別などの押せない `InfoChip` と見分けるため）。
/// 容器を持たないので、置いた先の `FlowLayout` にチップが 1 つずつ並ぶ（`FlowLayout` の入れ子は内側が 1 行のまま測られてはみ出す）。
struct EvidenceChips: View {
    let evidence: [Int]
    let resolve: (Int) -> EvidenceInfo?
    let onJump: (Int) -> Void

    var body: some View {
        if let first = evidence.first {
            // 引用符が行末に取り残されないよう、先頭のチップと組にする
            HStack(spacing: 4) {
                Image(systemName: "quote.opening")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                chip(first)
            }
            ForEach(evidence.dropFirst(), id: \.self) { chip($0) }
        }
    }

    private func chip(_ id: Int) -> some View {
        let info = resolve(id)
        return Button {
            onJump(id)
        } label: {
            HStack(spacing: 4) {
                Text(info?.time ?? "--:--:--")
                    .monospacedDigit()
                if let speaker = info?.speaker {
                    Text(speaker).lineLimit(1)
                }
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(info == nil ? .tertiary : .secondary)
        }
        .buttonStyle(ChipButtonStyle())
        .help(info.map { "\($0.speaker): \(Log.preview($0.text, limit: 80))" } ?? "以前の文字起こしの発話（#\(id)）")
    }
}

struct ActionRow: View {
    let action: MinutesSummary.ActionItem
    var selfName = "自分"
    let onToggle: (Bool) -> Void
    let resolve: (Int) -> EvidenceInfo?
    let onJump: (Int) -> Void

    private var done: Bool { action.done ?? false }

    /// 担当者。種別で自明な me / agent はチップを出さない。
    private var ownerTitle: String? {
        switch action.owner {
        case "me": action.kind == .ownCommitment ? nil : selfName
        case "agent": action.kind == .delegable ? nil : "エージェント"
        case "": nil
        default: action.owner
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("完了", isOn: Binding(get: { done }, set: { onToggle($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(action.text)
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .textSelection(.enabled)
                FlowLayout(spacing: 6) {
                    if let ownerTitle {
                        InfoChip(text: ownerTitle, systemImage: "person")
                    }
                    InfoChip(text: action.kind.title, tint: action.kind.tint)
                    if action.manual == true {
                        InfoChip(text: "手動", systemImage: "hand.point.up.left")
                    }
                    if let due = action.due {
                        let formatted = Formatting.due(due)
                        InfoChip(text: "期限 \(formatted.text)", systemImage: formatted.overdue && !done ? "calendar.badge.exclamationmark" : "calendar", tint: formatted.overdue && !done ? Palette.record : .secondary)
                            .help(due)
                    }
                    EvidenceChips(evidence: action.evidence, resolve: resolve, onJump: onJump)
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.snappy, value: done)
    }
}

struct SpeakerChip: View {
    let title: String
    let color: Color
    var assigned = true

    var body: some View {
        HStack(spacing: 4) {
            if !assigned {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.caption2)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.16), in: .capsule)
        .foregroundStyle(color)
    }
}

struct TranscriptRow<Speaker: View>: View {
    let segment: SegmentRecord
    let highlighted: Bool
    let isPlaying: Bool
    let isEditing: Bool
    /// 話者のポップオーバーを出している間は、どの発話か分かるよう行の強調を残す
    var isActive = false
    /// 背景の声として除外した話者の発話（開いて見せているとき）。薄く出す
    var isExcluded = false
    @Binding var editText: String
    let onPlay: () -> Void
    let onBeginEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    /// 話者チップ（割当のポップオーバーは呼び出し側がチップに付ける）
    @ViewBuilder var speaker: Speaker
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 4) {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.fill")
                        .font(.caption2)
                        .opacity(hovering || isPlaying ? 1 : 0)
                    Text(TimeFormatting.hms(segment.tStart))
                        .font(.caption.monospacedDigit())
                }
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
                .padding(.top, 2)
            }
            .buttonStyle(.plain)
            .frame(width: 78, alignment: .leading)
            .help("ここから再生")
            speaker
                .frame(width: 96, alignment: .leading)
            if isEditing {
                TextField("", text: $editText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onCommitEdit)
                    .onExitCommand(perform: onCancelEdit)
                HStack(spacing: 4) {
                    Button("保存", action: onCommitEdit).controlSize(.small).keyboardShortcut(.defaultAction)
                    Button("取消", action: onCancelEdit).controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    if !segment.isCurrent {
                        InfoChip(text: "以前の文字起こし", systemImage: "clock.arrow.circlepath")
                    }
                    Text(segment.text)
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
                Spacer(minLength: 0)
                Button(action: onBeginEdit) {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("本文を編集")
            }
        }
        .opacity(isExcluded ? 0.5 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground)
                .animation(.easeOut(duration: 0.15), value: isActive)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.smooth, value: highlighted)
        // 再生位置の強調は追従スクロールと同じ速さで移る
        .animation(Motion.follow, value: isPlaying)
    }

    private var rowBackground: AnyShapeStyle {
        if highlighted { return AnyShapeStyle(Color.yellow.opacity(0.22)) }
        if isPlaying { return AnyShapeStyle(Color.accentColor.opacity(0.10)) }
        if hovering || isActive { return AnyShapeStyle(Surface.hover) }
        return AnyShapeStyle(.clear)
    }
}

/// 話者割当のポップオーバー（参加者候補 → people → 自由入力）。
struct SpeakerAssignmentView: View {
    static let width: CGFloat = 300

    @Environment(AppModel.self) private var model
    let meeting: MeetingRecord
    let speaker: SpeakerRecord
    var selfName = "自分"
    /// 背景の声として除外する（true）・戻す（false）。相手側の話者のときだけ渡す。
    var onExclude: ((Bool) -> Void)?
    let onAssign: (String?, String?) -> Void
    @State private var customName = ""
    @State private var people: [PersonRecord] = []

    private var otherPeople: [PersonRecord] {
        let attendeeNames = Set(meeting.attendees.map(\.name))
        return people.filter { !attendeeNames.contains($0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SpeakerChip(title: SpeakerNaming.title(for: speaker, clusterLabel: speaker.clusterLabel, selfName: selfName), color: SpeakerPalette.color(for: speaker.clusterLabel))
                Text("の話者を割り当て").font(.headline)
            }
            if speaker.clusterLabel == TrackMerger.micSpeakerLabel {
                Text("マイクの声は自分として扱われます。表示名は設定 > 録音 で変更できます。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if !meeting.attendees.isEmpty {
                candidateSection("参加者") {
                    ForEach(meeting.attendees, id: \.self) { attendee in
                        candidateRow(name: attendee.name) {
                            let person = try? model.store?.findOrCreatePerson(name: attendee.name, email: attendee.email)
                            onAssign(person?.id, attendee.name)
                        }
                    }
                }
            }
            if !otherPeople.isEmpty {
                candidateSection("登録済み") {
                    ForEach(otherPeople) { person in
                        candidateRow(name: person.name) { onAssign(person.id, person.name) }
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("名前を入力", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitCustom)
                Button("割当", action: submitCustom)
                    .buttonStyle(.borderedProminent)
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if speaker.personId != nil || speaker.displayName != nil || onExclude != nil {
                HStack(spacing: 16) {
                    if speaker.personId != nil || speaker.displayName != nil {
                        Button(role: .destructive) {
                            onAssign(nil, nil)
                        } label: {
                            Label("割当を解除", systemImage: "person.slash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.record)
                    }
                    if let onExclude {
                        Button {
                            onExclude(!speaker.excluded)
                        } label: {
                            Label(speaker.excluded ? "除外をやめる" : "背景の声として除外", systemImage: speaker.excluded ? "arrow.uturn.backward" : "speaker.slash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(speaker.excluded
                              ? "本文・要約・書き出し・検索に戻します"
                              : "相手のマイクが拾った周りの会話などを外します。全文では折りたたみ、要約・書き出し・検索から外します（あとで戻せます）")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: Self.width)
        // 最初の描画より前に候補を読み、開いた後に吹き出しの大きさが変わらないようにする
        .onAppear { people = (try? model.store?.people()) ?? [] }
    }

    private func candidateSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            content()
        }
    }

    private func candidateRow(name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AvatarView(name: name, size: 22)
                Text(name).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
    }

    private func submitCustom() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let person = try? model.store?.findOrCreatePerson(name: name, email: nil)
        onAssign(person?.id, name)
    }
}

/// 1 発話に新しい名前を付ける（参加者候補 or 自由入力）。
struct SegmentNamingView: View {
    @Environment(AppModel.self) private var model
    let meeting: MeetingRecord
    let onName: (String, String?) -> Void
    @State private var customName = ""
    @State private var people: [PersonRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("この発話の話者").font(.headline)
            if !meeting.attendees.isEmpty {
                Text("参加者").font(.caption).foregroundStyle(.secondary)
                ForEach(meeting.attendees, id: \.self) { attendee in
                    Button {
                        onName(attendee.name, attendee.email)
                    } label: {
                        HStack(spacing: 8) {
                            AvatarView(name: attendee.name, size: 22)
                            Text(attendee.name).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }
            }
            if !people.isEmpty {
                Text("登録済み").font(.caption).foregroundStyle(.secondary)
                ForEach(people.prefix(8)) { person in
                    Button {
                        onName(person.name, person.email)
                    } label: {
                        HStack(spacing: 8) {
                            AvatarView(name: person.name, size: 22)
                            Text(person.name).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("名前を入力", text: $customName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("割当", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            let attendeeNames = Set(meeting.attendees.map(\.name))
            people = ((try? model.store?.people()) ?? []).filter { !attendeeNames.contains($0.name) }
        }
    }

    private func submit() {
        let name = customName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onName(name, nil)
    }
}

/// 最小限の Markdown ブロック表示（見出し・箇条書き・番号付き・段落）。
struct MarkdownBlocks: View {
    let text: String

    private struct Line: Identifiable {
        let id: Int
        let text: String
    }

    private var lines: [Line] {
        text.components(separatedBy: "\n").enumerated().map { Line(id: $0.offset, text: $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines) { line in
                block(for: line.text)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func block(for raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(raw.prefix(while: { $0 == " " }).count / 2) * 14
        if trimmed.isEmpty {
            Spacer().frame(height: 4)
        } else if trimmed.hasPrefix("#") {
            Text(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                .font(.headline)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(trimmed.dropFirst(2))))
            }
            .padding(.leading, indent)
        } else if let range = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            HStack(alignment: .top, spacing: 8) {
                Text(trimmed[range].trimmingCharacters(in: .whitespaces))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(inline(String(trimmed[range.upperBound...])))
            }
            .padding(.leading, indent)
        } else {
            Text(inline(trimmed))
        }
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string)) ?? AttributedString(string)
    }
}
