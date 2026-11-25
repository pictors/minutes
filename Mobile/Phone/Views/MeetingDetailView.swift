import MinutesKit
import SwiftUI

/// 会議の議事録と全文。
/// - 上の切り替えで「議事録」（要約・決まったこと・やること・確かめること）と「全文」（話者・発言）を行き来する。どちらかしかなければ切り替えは出さない。
/// - やることは済みを付けられる（サーバーの会議。iPhone・Watch の録音も、同期した Mac の会議も。Mac にも届く。P7）。
///   期限は「11/25（水）」・「今日」・「明日」で出し、過ぎたら色を変える（済みのものは変えない）。
/// - 決まったこと・やること・確かめることの根拠の時刻を押すと、全文のその発言へ飛び、音声があればそこから再生する。
/// - 全文は検索できる（当たった発言だけを出し、当たった所に色を付ける）。当たった発言を押すと、検索を解いてその発言から再生する。
/// - 全文は再生に合わせて今の発言を強調し、発言を押すとそこから再生する。題名が見えなくなるまで送ったら、上のバーに題名を出す。
struct MeetingDetailView: View {
    enum Tab: Hashable { case minutes, transcript }

    let clientId: String
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var summary: MinutesSummary?
    @State private var transcript: TranscriptDocument?
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var confirmingDelete = false
    @State private var player = AudioPlayback()
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var editingSpeakers = false
    @State private var sharing = false
    /// 読み込んだ結果、議事録がなかった（要約しなかった会議）
    @State private var summaryMissing = false
    @State private var tab: Tab = .minutes
    /// 全文の検索
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// 発言の ID → 発言（根拠の時刻を引く）と、そろえた本文（検索に使う）。全文を読んだときに作る
    @State private var segmentIndex: [Int: TranscriptDocument.Segment] = [:]
    @State private var foldedSegments: [Int: String] = [:]
    /// 検索に当たった発言（検索していなければ nil）
    @State private var matchingSegments: Set<Int>?
    /// 根拠や検索から飛んだ発言（少しのあいだ強調する）
    @State private var focusedSegment: Int?
    /// 全文に切り替えたあとで送る先の発言
    @State private var scrollTarget: Int?
    @State private var titleHeight: CGFloat = 40
    @State private var showsBarTitle = false
    /// サーバーへ送っている済み（送り終わるまで、同じやることは押せない）
    @State private var sendingChecks: Set<String> = []
    /// 済みを付けた・外した回数。読み直しが始まったあとに付けた済みがあれば、その読み直しの（古い）議事録で画面を戻さない
    @State private var checkRevision = 0
    @State private var checkFeedback = 0

    private var item: MeetingItem? { model.meetings.first { $0.id == clientId } }

    private var canPlay: Bool {
        guard let item else { return false }
        // 同期した Mac の会議は音声を送らない
        if item.isMacMeeting { return false }
        return (item.isDone && item.server?.audioDeleted != true) || model.localAudioURL(item) != nil
    }

    /// 話者の名前を直せる（サーバーにある会議。Mac の会議も。直したものは Mac にも届く。P7）。会議を消すのは iPhone・Watch で録った会議だけ
    private var canEdit: Bool { item?.server != nil }
    /// やることの済みを付けられる（サーバーで処理の終わった会議）
    private var canCheck: Bool { item?.isDone == true && item?.server != nil }
    private var hasTranscript: Bool { !(transcript?.segments.isEmpty ?? true) }
    private var summaryUnavailable: Bool { summaryMissing || item?.server?.summaryError != nil }
    private var showsTabs: Bool { summary != nil && hasTranscript }
    private var visibleTab: Tab {
        if showsTabs { return tab }
        return summary == nil && summaryUnavailable && hasTranscript ? .transcript : .minutes
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                if let item {
                    VStack(alignment: .leading, spacing: 14) {
                        header(item)
                        if let message = loadError ?? actionError {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(Palette.rose)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .cardBackground()
                                .transition(.opacity)
                        }
                        if let state = Formatting.state(item, recordingClientId: model.recorder.clientId), !item.isDone {
                            ProgressCard(item: item, state: state) { model.retryUpload(item) }
                        }
                        if showsTabs {
                            Picker("表示", selection: $tab) {
                                Text("議事録").tag(Tab.minutes)
                                Text("全文").tag(Tab.transcript)
                            }
                            .pickerStyle(.segmented)
                            .sensoryFeedback(.selection, trigger: tab)
                        }
                        switch visibleTab {
                        case .minutes: minutesContent(item)
                        case .transcript: transcriptContent()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, canPlay ? 140 : 24)
                    .animation(Motion.layout, value: summary != nil)
                    .animation(Motion.layout, value: transcript?.segments.count)
                    .animation(Motion.layout, value: visibleTab)
                } else {
                    ContentUnavailableView("会議が見つかりません", systemImage: "questionmark.folder")
                        .padding(.top, 80)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // 題名が上のバーに隠れたら、バーに題名を出す
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > titleHeight + 4
            } action: { _, hidden in
                showsBarTitle = hidden
            }
            .onChange(of: activeSegmentID) { _, id in
                guard let id, player.isPlaying, visibleTab == .transcript, matchingSegments == nil else { return }
                withAnimation(reduceMotion ? nil : Motion.follow) { scroll.scrollTo(id, anchor: .center) }
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                Task { @MainActor in
                    // 全文に切り替えた直後は行がまだ並んでいないので、一度描かせてから送る
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(reduceMotion ? nil : Motion.layout) { scroll.scrollTo(id, anchor: .center) }
                    scrollTarget = nil
                }
            }
        }
        .background(Surface.page.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if canPlay, let item {
                PlaybackBar(player: player) { await prepareAudio(item) }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .alert("会議の名前", isPresented: $renaming) {
            TextField("会議の名前", text: $titleDraft)
            Button("保存") { rename() }
                .disabled(item?.allowsEmptyTitle == false && titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("やめる", role: .cancel) {}
        }
        .sheet(isPresented: $editingSpeakers) {
            if let transcript {
                SpeakerNamesView(transcript: transcript) { names in
                    try await saveSpeakerNames(names)
                }
            }
        }
        .sheet(isPresented: $sharing) {
            if let server = item?.shareableRecording {
                ShareLinksView(recordingID: server.id, hasSummary: server.summaryError == nil && !summaryMissing)
                    // 会議の上に半分の高さで出す（リンクが増えたら引き上げて全体を見る）
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Surface.page)
            }
        }
        .task(id: item?.server?.status) { await load() }
        .refreshable {
            // 引き下げの仕事は、録音を読み直して画面が描き直されると取り消されることがある（PhoneModel.refresh と同じ）。
            // 取り消されない別の Task で読み、終わるまで待つ
            let reload = Task { @MainActor in
                if let id = item?.server?.id { await model.reloadServerRecording(id: id) }
                await load()
            }
            await reload.value
        }
        // Mac・ほかの端末で付けた済みを、前に出たときに読み直す
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .onChange(of: query) { updateMatches() }
        .sensoryFeedback(.success, trigger: checkFeedback)
        // 録音が始まったら（ウィジェットなどから。QuickRecordHandler が UIKit で閉じる）、この画面のシート・アラートの状態を戻す
        .onChange(of: model.recorder.isActive) { _, active in
            guard active else { return }
            sharing = false
            editingSpeakers = false
            renaming = false
            confirmingDelete = false
            searchFocused = false
            player.pause()
        }
        .onDisappear { player.stop() }
    }

    // MARK: 見出し

    @ViewBuilder
    private func header(_ item: MeetingItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title ?? MeetingItem.untitled)
                .brandDisplay(size: 30)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { titleHeight = $0 }
            Text("\(Formatting.dayTitle(item.startedAt)) \(Formatting.timeOfDay(item.startedAt))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            FlowRow(spacing: 6) {
                if let duration = item.durationSeconds {
                    InfoChip(text: Formatting.duration(duration), systemImage: "clock")
                }
                if let count = item.server?.speakerCount, count > 0 {
                    InfoChip(text: "\(count) 人", systemImage: "person.2.fill")
                }
                InfoChip(text: item.origin.text, systemImage: item.origin.systemImage)
                if let gaps = item.local?.gaps, !gaps.isEmpty {
                    InfoChip(text: "録れていない時間 \(gaps.count) か所", systemImage: "scissors")
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    // MARK: 議事録

    @ViewBuilder
    private func minutesContent(_ item: MeetingItem) -> some View {
        if let summary {
            summaryCards(summary)
                .transition(Motion.content(reduceMotion: reduceMotion))
        } else if item.isDone, loadError == nil, !summaryUnavailable {
            HStack(spacing: 10) {
                ProgressView()
                Text("議事録を読んでいます").foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
        }
    }

    @ViewBuilder
    private func summaryCards(_ summary: MinutesSummary) -> some View {
        // 要約の文がない議事録（Mac で手で足したやることだけの会議など）は、要約のカードを出さない
        if !summary.summaryMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SectionCard("要約", systemImage: "sparkles", tint: Palette.violet) {
                SummaryBody(markdown: summary.summaryMd)
            }
        }
        if !summary.decisions.isEmpty {
            SectionCard("決まったこと", systemImage: "checkmark.seal.fill", count: summary.decisions.count, tint: Palette.mint) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                        bulletRow(decision.text, symbol: "checkmark", tint: Palette.mint, evidence: decision.evidence)
                    }
                }
            }
        }
        if !summary.actionItems.isEmpty {
            let doneCount = summary.actionItems.count { $0.done == true }
            SectionCard(title: "やること", systemImage: "checklist", count: summary.actionItems.count, tint: Palette.periwinkle) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, action in
                        actionRow(action)
                    }
                }
            } trailing: {
                if doneCount > 0 {
                    Text("\(doneCount) 件 済み")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
            }
        }
        if !summary.openQuestions.isEmpty {
            SectionCard("確かめること", systemImage: "questionmark.circle.fill", count: summary.openQuestions.count, tint: Palette.amber) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(summary.openQuestions.enumerated()), id: \.offset) { _, question in
                        bulletRow(question.text, symbol: "questionmark", tint: Palette.amber, evidence: question.evidence)
                    }
                }
            }
        }
    }

    private func bulletRow(_ text: String, symbol: String, tint: Color, evidence: [Int]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            evidenceButton(evidence)
        }
    }

    /// やること: 済みのボタン、本文、担当者・期限・根拠の時刻
    private func actionRow(_ action: MinutesSummary.ActionItem) -> some View {
        let done = action.done == true
        let sending = action.id.map { sendingChecks.contains($0) } ?? false
        let owner = Formatting.owner(action.owner, in: transcript)
        let due = action.due.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let evidence = evidenceSegment(action.evidence)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                toggle(action)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(done ? Palette.mint : Color.secondary.opacity(0.6))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canCheck || action.id == nil || sending)
            .opacity(sending ? 0.5 : 1)
            .accessibilityLabel(done ? "済みを外す" : "済みにする")
            .accessibilityValue(done ? "済み" : "まだ")
            VStack(alignment: .leading, spacing: 6) {
                Text(action.text)
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if owner != nil || due != nil || evidence != nil {
                    FlowRow(spacing: 6) {
                        if let owner {
                            HStack(spacing: 5) {
                                if action.owner == "agent" {
                                    Image(systemName: "sparkles")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Palette.violet)
                                        .frame(width: 18, height: 18)
                                } else {
                                    SpeakerBadge(label: action.owner, name: owner, size: 18)
                                }
                                Text(owner)
                            }
                            .font(.caption.weight(.medium))
                            .padding(.leading, 3)
                            .padding(.trailing, 8)
                            .padding(.vertical, 3)
                            .background(Surface.raised, in: .capsule)
                        }
                        if let due { DueChip(due: Formatting.due(due), done: done) }
                        evidenceButton(action.evidence)
                    }
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.press, value: done)
    }

    /// 根拠の発言の時刻（押すと全文のその発言へ飛び、音声があればそこから再生する）。全文にない発言（同期した会議で外した話者など）なら出さない
    @ViewBuilder
    private func evidenceButton(_ ids: [Int]) -> some View {
        if let segment = evidenceSegment(ids) {
            Button {
                jump(to: segment)
            } label: {
                Label(Formatting.clock(segment.tStart), systemImage: canPlay ? "play.fill" : "text.quote")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.periwinkle.opacity(0.12), in: .capsule)
                    .foregroundStyle(Palette.periwinkle)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Formatting.clock(segment.tStart)) の発言を全文で見る")
        }
    }

    private func evidenceSegment(_ ids: [Int]) -> TranscriptDocument.Segment? {
        ids.compactMap { segmentIndex[$0] }.min { $0.tStart < $1.tStart }
    }

    // MARK: 話者と全文

    @ViewBuilder
    private func transcriptContent() -> some View {
        if let transcript {
            if !transcript.speakers.isEmpty {
                speakersCard(transcript)
            }
            if !transcript.segments.isEmpty {
                searchField
                transcriptCard(transcript)
                    .transition(Motion.content(reduceMotion: reduceMotion))
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("全文を検索", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if let matchingSegments {
                Text("\(matchingSegments.count) 件")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索の文字を消す")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, matchingSegments == nil ? 14 : 6)
        .frame(height: 44)
        .background(Surface.card, in: .capsule)
    }

    private func speakersCard(_ transcript: TranscriptDocument) -> some View {
        SectionCard(title: "話者", systemImage: "person.2.fill", count: transcript.speakers.count, tint: .secondary) {
            FlowRow(spacing: 8) {
                ForEach(transcript.speakers, id: \.label) { speaker in
                    let name = Formatting.speaker(speaker.label, in: transcript)
                    HStack(spacing: 6) {
                        SpeakerBadge(label: speaker.label, name: name, size: 22)
                        Text(name).font(.subheadline.weight(.medium))
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                    .padding(.vertical, 4)
                    .background(Surface.raised, in: .capsule)
                }
            }
        } trailing: {
            if canEdit {
                Button("名前を付ける") { editingSpeakers = true }
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    private var activeSegmentID: Int? {
        guard let transcript, player.isReady, player.currentTime > 0 || player.isPlaying else { return nil }
        let time = player.currentTime
        return transcript.segments.last { $0.tStart <= time + 0.05 }?.id
    }

    private func transcriptCard(_ transcript: TranscriptDocument) -> some View {
        let terms = matchingSegments == nil ? [] : TextSearch.terms(query)
        let segments = matchingSegments.map { ids in transcript.segments.filter { ids.contains($0.id) } } ?? transcript.segments
        return SectionCard("全文", systemImage: "text.alignleft", tint: .secondary) {
            if segments.isEmpty {
                Text("当てはまる発言はありません")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(segments, id: \.id) { segment in
                        segmentRow(segment, transcript: transcript, terms: terms)
                    }
                }
                .padding(.horizontal, -8)
            }
        }
    }

    private func segmentRow(_ segment: TranscriptDocument.Segment, transcript: TranscriptDocument, terms: [String]) -> some View {
        let name = Formatting.speaker(segment.speaker, in: transcript)
        let active = segment.id == activeSegmentID || segment.id == focusedSegment
        let tint = SpeakerPalette.color(for: segment.speaker)
        return Button {
            // 検索で絞っているときは、検索を解いてその発言へ（前後も読めるように）
            if terms.isEmpty { play(from: segment) } else { jump(to: segment) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                SpeakerBadge(label: segment.speaker, name: name, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                        Text(Formatting.clock(segment.tStart))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    Text(terms.isEmpty ? AttributedString(segment.text) : TextSearch.highlighted(segment.text, terms: terms, tint: Palette.amber))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(active ? tint.opacity(0.14) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .id(segment.id)
        .animation(Motion.follow, value: active)
    }

    // MARK: 操作

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // 題名が上のバーに隠れたら、バーに出す
        ToolbarItem(placement: .principal) {
            Text(item?.title ?? MeetingItem.untitled)
                .font(.headline)
                .lineLimit(1)
                .opacity(showsBarTitle ? 1 : 0)
                .animation(Motion.press, value: showsBarTitle)
                .accessibilityHidden(!showsBarTitle)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if item?.canRename == true {
                    Button {
                        titleDraft = item?.title ?? ""
                        renaming = true
                    } label: {
                        Label("名前を変える", systemImage: "pencil")
                    }
                }
                if let transcript, !transcript.speakers.isEmpty, canEdit {
                    Button {
                        editingSpeakers = true
                    } label: {
                        Label("話者の名前", systemImage: "person.2")
                    }
                }
                if item?.shareableRecording != nil {
                    Button {
                        sharing = true
                    } label: {
                        Label("リンクで共有…", systemImage: "link")
                    }
                }
                if item?.canDelete == true {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("会議を消す", systemImage: "trash")
                    }
                    // アプリ全体の色（青紫）が、メニューの消す記号にも付いてしまうので、文字と同じ赤にする
                    .tint(.red)
                    .disabled(item?.id == model.recorder.clientId)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("会議の操作")
            .disabled(item == nil)
            // 確認は操作のメニューから出す（画面全体に付けると、関係のない場所から出る）
            .confirmationDialog("この会議を消しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("消す", role: .destructive) { delete() }
            } message: {
                Text("音声・文字起こし・議事録を、この iPhone とサーバーから消します。元に戻せません。")
            }
        }
    }

    /// その発言から再生する（音声がなければ何もしない）
    private func play(from segment: TranscriptDocument.Segment) {
        guard let item, canPlay else { return }
        player.seek(to: segment.tStart)
        if player.isReady { player.play() } else { Task { await prepareAudio(item) } }
    }

    /// 全文のその発言へ飛ぶ（検索を解き、全文に切り替えて送り、少しのあいだ強調する。音声があればそこから再生する）
    private func jump(to segment: TranscriptDocument.Segment) {
        query = ""
        searchFocused = false
        if visibleTab != .transcript { tab = .transcript }
        focusedSegment = segment.id
        scrollTarget = segment.id
        play(from: segment)
        let id = segment.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if focusedSegment == id { withAnimation(Motion.layout) { focusedSegment = nil } }
        }
    }

    /// やることの済みを付ける・外す。先に画面を変え、サーバーへ送れなかったら戻す
    private func toggle(_ action: MinutesSummary.ActionItem) {
        guard let item, let id = action.id, var current = summary, let index = current.actionItems.firstIndex(where: { $0.id == id }) else { return }
        let done = current.actionItems[index].done != true
        current.actionItems[index].done = done
        summary = current
        checkRevision += 1
        sendingChecks.insert(id)
        if done { checkFeedback += 1 }
        Task {
            defer { sendingChecks.remove(id) }
            do {
                try await model.setActionDone(item, actionID: id, done: done)
                actionError = nil
            } catch {
                if var latest = summary, let i = latest.actionItems.firstIndex(where: { $0.id == id }) {
                    latest.actionItems[i].done = !done
                    summary = latest
                }
                withAnimation(Motion.layout) { actionError = Self.checkErrorText(error) }
            }
        }
    }

    static func checkErrorText(_ error: Error) -> String {
        if let cloud = error as? MinutesCloudError, cloud.status == 404 {
            // 済みを受け付けないサーバー（道がない）と、サーバーにないやること
            if cloud.code == "not_found" { return "サーバーが、まだやることの済みを受け付けていません" }
            return "このやることはサーバーにありません。下に引いて読み直してください"
        }
        return "済みを保存できませんでした（\(error.localizedDescription)）"
    }

    private func prepareAudio(_ item: MeetingItem) async {
        let remote = item.isDone && item.server?.audioDeleted != true ? item.server?.id : nil
        await player.load(remoteID: remote, localURL: model.localAudioURL(item), client: model.client)
    }

    private func load() async {
        guard let server = item?.server, server.status == "done" else { return }
        let revision = checkRevision
        do {
            async let summary = server.summaryError == nil ? Self.summaryIfAny(model.client, recordingID: server.id) : nil
            async let transcript = model.client.transcript(recordingID: server.id)
            let document = try await transcript
            let loadedSummary = try await summary
            self.transcript = document
            indexSegments(document)
            // 済みを送っているあいだと、読み始めたあとに済みを変えたときは、古い済みで画面を戻さない（次の読み直しで合う）
            if sendingChecks.isEmpty, revision == checkRevision { self.summary = loadedSummary }
            summaryMissing = loadedSummary == nil
            loadError = nil
        } catch where PhoneModel.isCancellation(error) {
            // 画面を離れた・読み直しに替わった（誤りとして出さない）
        } catch {
            loadError = "議事録を読めませんでした（\(error.localizedDescription)）"
        }
    }

    /// 根拠の時刻と検索のために、発言を ID で引けるようにし、検索用にそろえた本文（話者の名前を含む）を作る
    private func indexSegments(_ document: TranscriptDocument) {
        segmentIndex = Dictionary(document.segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        foldedSegments = Dictionary(document.segments.map { ($0.id, TextSearch.folded("\(Formatting.speaker($0.speaker, in: document)) \($0.text)")) },
                                    uniquingKeysWith: { first, _ in first })
        updateMatches()
    }

    private func updateMatches() {
        let terms = TextSearch.terms(query).map(TextSearch.folded)
        guard !terms.isEmpty, let transcript else {
            matchingSegments = nil
            return
        }
        matchingSegments = Set(transcript.segments.compactMap { segment in
            let haystack = foldedSegments[segment.id] ?? ""
            return terms.allSatisfy { haystack.contains($0) } ? segment.id : nil
        })
    }

    /// 議事録。ない（404。要約しなかった Mac の会議など）なら nil
    private static func summaryIfAny(_ client: MinutesCloudClient, recordingID: String) async throws -> MinutesSummary? {
        do {
            return try await client.summary(recordingID: recordingID)
        } catch let error as MinutesCloudError where error.status == 404 {
            return nil
        }
    }

    private func rename() {
        guard let item else { return }
        let title = titleDraft
        Task {
            do {
                try await model.rename(item, title: title)
                actionError = nil
            } catch {
                actionError = "名前を変えられませんでした（\(error.localizedDescription)）"
            }
        }
    }

    private func saveSpeakerNames(_ names: [String: String]) async throws {
        guard let item, let server = item.server else { return }
        try await model.renameSpeakers(item, names: names)
        let document = try await model.client.transcript(recordingID: server.id)
        transcript = document
        indexSegments(document)
    }

    private func delete() {
        guard let item else { return }
        Task {
            do {
                try await model.delete(item)
                dismiss()
            } catch {
                actionError = "消せませんでした（\(error.localizedDescription)）"
            }
        }
    }
}

/// やることの期限（「11/25（水）」・「今日」・「明日」）。過ぎたものは薔薇色、今日のものは琥珀色（済みのものは色を付けない）。
private struct DueChip: View {
    let due: Formatting.Due
    let done: Bool

    private var tint: Color? {
        guard !done else { return nil }
        switch due.timing {
        case .overdue: return Palette.rose
        case .today: return Palette.amber
        case .upcoming, .unknown: return nil
        }
    }

    var body: some View {
        Label(due.text, systemImage: tint == nil ? "calendar" : (due.timing == .overdue ? "calendar.badge.exclamationmark" : "calendar.badge.clock"))
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(tint == nil ? .regular : .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.map { $0.opacity(0.14) } ?? Surface.raised, in: .capsule)
            .foregroundStyle(tint ?? .secondary)
            .fixedSize()
            .accessibilityLabel("期限 \(due.spoken)")
    }
}

/// 送信・文字起こし・議事録の進み具合（終わるまで）。
private struct ProgressCard: View {
    let item: MeetingItem
    let state: MeetingState
    let retry: () -> Void

    private var step: Int {
        if state.isError { return -1 }
        switch item.server?.status {
        case "queued", "transcribing": return 1
        case "summarizing": return 2
        default: return 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusPill(text: state.text, tint: state.tint, systemImage: state.systemImage, isBusy: state.isBusy)
            if !state.isError, item.local?.stopped != false || item.server != nil {
                HStack(spacing: 6) {
                    ForEach(Array(["送る", "文字起こし", "議事録"].enumerated()), id: \.offset) { index, title in
                        VStack(alignment: .leading, spacing: 6) {
                            Capsule()
                                .fill(index < step ? Palette.mint : (index == step ? state.tint : Surface.raised))
                                .frame(height: 5)
                            Text(title)
                                .font(.caption2.weight(index == step ? .semibold : .regular))
                                .foregroundStyle(index <= step ? .primary : .tertiary)
                        }
                    }
                }
                .animation(Motion.layout, value: step)
                Text("終わるまで 1〜2 分ほどです。アプリを閉じても進みます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if state.isError, item.local.map({ !$0.completed }) == true {
                Button("もう一度送る", action: retry)
                    .buttonStyle(FilledPillButtonStyle(height: 44))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// 要約の Markdown を組む（結論の太字の行、箇条書き、入れ子の箇条書き）。
private struct SummaryBody: View {
    let markdown: String

    private struct Line: Identifiable {
        let id: Int
        let text: AttributedString
        let indent: Int
        let isBullet: Bool
        let isLead: Bool
    }

    private var lines: [Line] {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { index, raw in
            let spaces = raw.prefix { $0 == " " }.count
            var body = raw.dropFirst(spaces)
            let isBullet = body.hasPrefix("- ") || body.hasPrefix("* ")
            if isBullet { body = body.dropFirst(2) }
            while body.hasPrefix("#") { body = body.dropFirst() }
            let source = body.trimmingCharacters(in: .whitespaces)
            let text = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
            return Line(id: index, text: text, indent: spaces / 2, isBullet: isBullet, isLead: !isBullet && source.hasPrefix("**"))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(lines) { line in
                if line.isBullet {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Circle()
                            .fill(line.indent > 0 ? Color.secondary.opacity(0.5) : Palette.violet)
                            .frame(width: line.indent > 0 ? 4 : 5, height: line.indent > 0 ? 4 : 5)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(line.text)
                            .foregroundStyle(line.indent > 0 ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(min(line.indent, 3)) * 16)
                } else {
                    Text(line.text)
                        .font(line.isLead ? .body.weight(.semibold) : .body)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, line.isLead ? 2 : 0)
                }
            }
        }
        .textSelection(.enabled)
    }
}

/// 下に浮かぶ再生バー: 上の段に位置と時間、下の段に速さ・15 秒戻す・再生・15 秒送る。速さは止めても変わらない。
private struct PlaybackBar: View {
    let player: AudioPlayback
    let prepare: () async -> Void
    @State private var scrubbing: Double?

    private var rateText: String { String(format: "%g×", player.rate) }

    var body: some View {
        VStack(spacing: 2) {
            if let error = player.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Palette.rose)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            } else {
                HStack(spacing: 10) {
                    Text(Formatting.clock(scrubbing ?? player.currentTime))
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .frame(minWidth: 38, alignment: .leading)
                    Slider(value: Binding(get: { scrubbing ?? player.currentTime }, set: { scrubbing = $0 }), in: 0...max(player.duration, 1)) { editing in
                        if !editing, let value = scrubbing {
                            player.seek(to: value)
                            scrubbing = nil
                        }
                    }
                    .tint(Palette.periwinkle)
                    .disabled(!player.isReady)
                    Text(player.isReady ? Formatting.clock(player.duration) : "--:--")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 38, alignment: .trailing)
                }
                .frame(minHeight: 30)
            }
            HStack(spacing: 0) {
                Button {
                    player.cycleRate()
                } label: {
                    Text(rateText)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(width: 56, height: 40)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("再生の速さ")
                .accessibilityValue(rateText)
                Spacer(minLength: 0)
                skipButton(-15, systemImage: "gobackward.15", label: "15 秒戻す")
                Button {
                    if player.isReady {
                        player.toggle()
                    } else {
                        Task {
                            await prepare()
                            player.play()
                        }
                    }
                } label: {
                    ZStack {
                        if player.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .bold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 50, height: 50)
                    .background(Surface.raised, in: .circle)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")
                skipButton(15, systemImage: "goforward.15", label: "15 秒送る")
                Spacer(minLength: 0)
                // 速さのボタンと左右をそろえる
                Color.clear.frame(width: 56, height: 40)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 30, style: .continuous))
        .sensoryFeedback(.selection, trigger: player.rate)
    }

    private func skipButton(_ seconds: Double, systemImage: String, label: String) -> some View {
        Button {
            player.skip(by: seconds)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .frame(width: 46, height: 46)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!player.isReady)
        .accessibilityLabel(label)
    }
}

/// 折り返す横並び（チップ）。
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(bounds.width, subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), points)
    }
}
