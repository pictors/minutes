import MinutesKit
import SwiftUI

/// 会議の議事録（要約・決まったこと・やること・確かめること）、話者、全文、音声。
/// 全文は再生に合わせて今の発言を強調し、発言を押すとそこから再生する。
struct MeetingDetailView: View {
    let clientId: String
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
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

    private var item: MeetingItem? { model.meetings.first { $0.id == clientId } }

    /// リンクで共有できる会議（iPhone・Watch で録って、サーバーで処理が終わったものと、同期した Mac の会議。P7）
    private var shareableRecording: MinutesCloudRecording? {
        guard let server = item?.server, server.status == "done", server.isSyncedMeeting || ["iphone", "watch"].contains(server.source ?? "") else { return nil }
        return server
    }

    private var canPlay: Bool {
        guard let item else { return false }
        // 同期した Mac の会議は音声を送らない
        if item.isMacMeeting { return false }
        return (item.isDone && item.server?.audioDeleted != true) || model.localAudioURL(item) != nil
    }

    /// 題名・話者の名前を直す・会議を消すのは、iPhone・Watch で録った会議だけ（Mac の会議は Mac が正。P7 の最初の段は一方向）
    private var canEdit: Bool { item?.isMacMeeting != true }

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
                        }
                        if let state = Formatting.state(item, recordingClientId: model.recorder.clientId), !item.isDone {
                            ProgressCard(item: item, state: state) { model.retryUpload(item) }
                        }
                        if let summary {
                            summaryCards(summary)
                                .transition(Motion.content(reduceMotion: reduceMotion))
                        } else if item.isDone, loadError == nil, item.server?.summaryError == nil {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("議事録を読んでいます").foregroundStyle(.secondary)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardBackground()
                        }
                        if let transcript, !transcript.speakers.isEmpty {
                            speakersCard(transcript)
                        }
                        if item.isMacMeeting {
                            Label("Mac から同期した会議です。題名や話者の名前は Mac で直してください。", systemImage: "laptopcomputer")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                        }
                        if let transcript, !transcript.segments.isEmpty {
                            transcriptCard(transcript)
                                .transition(Motion.content(reduceMotion: reduceMotion))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, canPlay ? 96 : 24)
                    .animation(Motion.layout, value: summary != nil)
                    .animation(Motion.layout, value: transcript?.segments.count)
                } else {
                    ContentUnavailableView("会議が見つかりません", systemImage: "questionmark.folder")
                        .padding(.top, 80)
                }
            }
            .onChange(of: activeSegmentID) { _, id in
                guard let id, player.isPlaying else { return }
                withAnimation(reduceMotion ? nil : Motion.follow) { scroll.scrollTo(id, anchor: .center) }
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
            if let server = shareableRecording {
                ShareLinksView(recordingID: server.id, hasSummary: server.summaryError == nil)
            }
        }
        .task(id: item?.server?.status) { await load() }
        .refreshable {
            if let id = item?.server?.id { await model.reloadServerRecording(id: id) }
            await load()
        }
        .onDisappear { player.stop() }
    }

    // MARK: 見出し

    @ViewBuilder
    private func header(_ item: MeetingItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title ?? "無題の会議")
                .brandDisplay(size: 30)
                .fixedSize(horizontal: false, vertical: true)
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
    private func summaryCards(_ summary: MinutesSummary) -> some View {
        SectionCard("要約", systemImage: "sparkles", tint: Palette.violet) {
            SummaryBody(markdown: summary.summaryMd)
        }
        if !summary.decisions.isEmpty {
            SectionCard("決まったこと", systemImage: "checkmark.seal.fill", count: summary.decisions.count, tint: Palette.mint) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                        bulletRow(decision.text, symbol: "checkmark", tint: Palette.mint)
                    }
                }
            }
        }
        if !summary.actionItems.isEmpty {
            SectionCard("やること", systemImage: "checklist", count: summary.actionItems.count, tint: Palette.periwinkle) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, action in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(action.text)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                if let name = Formatting.owner(action.owner, in: transcript) {
                                    HStack(spacing: 5) {
                                        if action.owner == "agent" {
                                            Image(systemName: "sparkles")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(Palette.violet)
                                                .frame(width: 18, height: 18)
                                        } else {
                                            SpeakerBadge(label: action.owner, name: name, size: 18)
                                        }
                                        Text(name)
                                    }
                                    .font(.caption.weight(.medium))
                                    .padding(.leading, 3)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 3)
                                    .background(Surface.raised, in: .capsule)
                                }
                                if let due = action.due, !due.isEmpty {
                                    InfoChip(text: due, systemImage: "calendar")
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        if !summary.openQuestions.isEmpty {
            SectionCard("確かめること", systemImage: "questionmark.circle.fill", count: summary.openQuestions.count, tint: Palette.amber) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(summary.openQuestions.enumerated()), id: \.offset) { _, question in
                        bulletRow(question.text, symbol: "questionmark", tint: Palette.amber)
                    }
                }
            }
        }
    }

    private func bulletRow(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 話者と全文

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
        SectionCard("全文", systemImage: "text.alignleft", tint: .secondary) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(transcript.segments, id: \.id) { segment in
                    let name = Formatting.speaker(segment.speaker, in: transcript)
                    let active = segment.id == activeSegmentID
                    Button {
                        guard let item, canPlay else { return }
                        player.seek(to: segment.tStart)
                        if player.isReady { player.play() } else { Task { await prepareAudio(item) } }
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            SpeakerBadge(label: segment.speaker, name: name, size: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(name).font(.caption.weight(.semibold))
                                        .foregroundStyle(SpeakerPalette.color(for: segment.speaker))
                                    Text(Formatting.clock(segment.tStart))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                                Text(segment.text)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 8)
                        .background(active ? SpeakerPalette.color(for: segment.speaker).opacity(0.12) : .clear, in: .rect(cornerRadius: 12, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .id(segment.id)
                    .animation(Motion.follow, value: active)
                }
            }
            .padding(.horizontal, -8)
        }
    }

    // MARK: 操作

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if item?.server != nil, canEdit {
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
                if shareableRecording != nil {
                    Button {
                        sharing = true
                    } label: {
                        Label("リンクで共有…", systemImage: "link")
                    }
                }
                if canEdit {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("会議を消す", systemImage: "trash")
                    }
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

    private func prepareAudio(_ item: MeetingItem) async {
        let remote = item.isDone && item.server?.audioDeleted != true ? item.server?.id : nil
        await player.load(remoteID: remote, localURL: model.localAudioURL(item), client: model.client)
    }

    private func load() async {
        guard let server = item?.server, server.status == "done" else { return }
        do {
            async let summary = server.summaryError == nil ? model.client.summary(recordingID: server.id) : nil
            async let transcript = model.client.transcript(recordingID: server.id)
            self.transcript = try await transcript
            self.summary = try await summary
            loadError = nil
        } catch where PhoneModel.isCancellation(error) {
            // 画面を離れた・読み直しに替わった（誤りとして出さない）
        } catch {
            loadError = "議事録を読めませんでした（\(error.localizedDescription)）"
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
        transcript = try await model.client.transcript(recordingID: server.id)
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

/// 下に浮かぶ再生バー（再生・位置・時間）。
private struct PlaybackBar: View {
    let player: AudioPlayback
    let prepare: () async -> Void
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 12) {
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
                            .font(.system(size: 18, weight: .bold))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 44, height: 44)
                .background(Surface.raised, in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "一時停止" : "再生")

            if let error = player.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Palette.rose)
                    .lineLimit(2)
                Spacer(minLength: 0)
            } else {
                Text(Formatting.clock(scrubbing ?? player.currentTime))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .frame(minWidth: 36, alignment: .trailing)
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
                    .frame(minWidth: 36, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 64)
        .glassEffect(.regular, in: .capsule)
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
