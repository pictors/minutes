import MinutesCore
import SwiftUI

/// 録音中の右ペイン: ライブ字幕 + 自分用メモ（SPEC §10.2）。録音対象アプリ名を明示する（§6.2）。
struct RecordingView: View {
    @Environment(AppModel.self) private var model
    let meeting: MeetingRecord?
    /// 画面に出す状態（バナー・録音対象アプリなど）。表示が変わるときだけ更新する（`SessionSnapshot.sameDisplay`）。
    @State private var snapshot: SessionSnapshot?
    @State private var systemLevel = LevelFeed()
    @State private var micLevel = LevelFeed()
    private var notesDraft: UserNotesDraft? { meeting.map { model.notesDraft(for: $0.id) } }

    var body: some View {
        VStack(spacing: 16) {
            RecordingHeader(meeting: meeting, snapshot: snapshot, systemLevel: systemLevel, micLevel: micLevel)
            if snapshot?.awaitingStartConfirmation == true || model.awaitingStartConfirmation {
                Banner(kind: .info, text: "会議の音声を検知しました。録音を開始しますか？", actionTitle: "録音を開始", action: { model.startNow() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let error = snapshot?.lastError {
                Banner(kind: .error, text: error,
                       actionTitle: error.contains("許可") || error.contains("権限") ? "システム設定を開く" : nil,
                       action: { SystemSettingsLink.openPrivacy(forError: error) })
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let warning = snapshot?.interruptionWarning {
                Banner(kind: .warning, text: warning)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let error = notesDraft?.saveError {
                Banner(kind: .error, text: error, actionTitle: "メモを再保存", action: { notesDraft?.flush() })
            }
            HSplitView {
                LiveCaptionsPane()
                    .frame(minWidth: 340)
                    .layoutPriority(1)
                NotesPane(notes: Binding(get: { notesDraft?.text ?? "" }, set: { notesDraft?.edit($0) }))
                    .frame(minWidth: 260)
                    .disabled(notesDraft == nil)
            }
        }
        .padding(20)
        .animation(.smooth, value: snapshot?.lastError)
        .animation(.smooth, value: snapshot?.awaitingStartConfirmation)
        .animation(.smooth, value: snapshot?.interruptedTracks)
        .navigationTitle(meeting?.title ?? "録音")
        .navigationSubtitle(model.sessionState.title)
        .task(id: meeting?.id) {
            if let meeting, let existing = try? model.store?.notes(meetingId: meeting.id)?.userNotesMd {
                notesDraft?.receivePersisted(existing)
            }
            // 音量メーターは 5 Hz。監視周期（5 秒）とは独立に録音側から直接読む。
            // 音量は AppKit のメーターへ直接渡し、SwiftUI の状態は表示が変わるときだけ替える
            // （状態を替えるたびにウィンドウ全体のレイアウトをやり直すので、1 秒 5 回だと main スレッドを 18% 使っていた。G7）。
            // 経過時間は AppModel が秒の切り替わりごとに更新する。
            while !Task.isCancelled {
                let latest = await model.session?.snapshot()
                if let latest {
                    systemLevel.send(latest.systemLevelDb)
                    micLevel.send(latest.micLevelDb)
                }
                if !SessionSnapshot.sameDisplay(snapshot, latest) { snapshot = latest }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .onAppear { model.setRecordingSurface("window", visible: true) }
        .onDisappear {
            notesDraft?.flush()
            model.setRecordingSurface("window", visible: false)
        }
    }
}

extension SessionSnapshot {
    /// 途切れているトラックの呼び名（「マイクの音声」など）。片方が途切れても録音は続けている（SPEC §4.3）。
    var interruptedTrackNames: String? {
        guard !interruptedTracks.isEmpty else { return nil }
        return interruptedTracks.map { $0 == "system" ? "会議アプリの音声" : "マイクの音声" }.joined(separator: "と")
    }

    var interruptionWarning: String? {
        interruptedTrackNames.map { "\($0)が届いていません。録音は続けています。接続を確認してください。" }
    }

    /// 画面に出す内容が同じか。経過時間と音量は比べない（経過時間は AppModel、音量は `LevelFeed` が別に届ける）。
    static func sameDisplay(_ a: SessionSnapshot?, _ b: SessionSnapshot?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            true
        case let (a?, b?):
            a.state == b.state && a.meeting == b.meeting && a.tappedProcessNames == b.tappedProcessNames
                && a.lastError == b.lastError && a.awaitingStartConfirmation == b.awaitingStartConfirmation
                && a.interruptedTracks == b.interruptedTracks
        default:
            false
        }
    }
}

/// 状態・経過時間・音量・停止ボタン（メニューバーのパネルと同じ部品）。
struct RecordingHeader: View {
    @Environment(AppModel.self) private var model
    let meeting: MeetingRecord?
    let snapshot: SessionSnapshot?
    let systemLevel: LevelFeed
    let micLevel: LevelFeed

    private var tappedApps: String? {
        guard let names = snapshot?.tappedProcessNames, !names.isEmpty else { return nil }
        return Array(Set(names)).sorted().joined(separator: ", ")
    }

    private var subtitle: String {
        let state = model.sessionState
        if let tappedApps { return "\(state.title) · \(tappedApps)" }
        if state == .armed { return "\(state.title) · \(state.detail)" }
        return state.title
    }

    var body: some View {
        let state = model.sessionState
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TintedTile(
                    systemImage: state == .recording ? (meeting?.meetingPlatform ?? .other).symbol : state.symbol,
                    tint: state.tint,
                    size: 30,
                    pulse: state == .recording
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting?.title ?? "録音準備中")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(subtitle)
                            .lineLimit(1)
                        // 専用ブラウザの説明（SPEC §12）。録っているアプリの音は、会議以外の音も入る
                        if let tappedApps {
                            Image(systemName: "info.circle")
                                .help("\(tappedApps) から出る音は、ほかのタブの動画や通知音も含めてすべて録音されます。会議は会議専用のブラウザで開いてください。")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                NoticeCopyButton()
                if let meeting, state == .recording || state == .finalizing {
                    Text("\(meeting.startedAt.formatted(date: .omitted, time: .shortened)) から")
                        .font(.system(size: 12.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                BigTimerText(seconds: model.windowElapsedSeconds, size: 46, isDimmed: state == .armed)
                Spacer(minLength: 12)
                if snapshot != nil {
                    VStack(alignment: .trailing, spacing: 6) {
                        MeterLabel(title: "会議", feed: systemLevel, tint: Palette.periwinkle)
                        MeterLabel(title: model.selfDisplayName, feed: micLevel, tint: SpeakerPalette.me)
                    }
                }
                if state == .armed {
                    Button {
                        model.stopRecording()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 40))
                    .help("録音準備をキャンセル（⇧⌘.）")
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                }
                primaryPill(state)
            }
        }
        .padding(16)
        .cardBackground()
        .animation(.smooth, value: state)
    }

    /// 主操作のピル。今すぐ開始 / 停止 / 録音を終了 を 1 つのボタンが担い、状態が変わるとカプセルが幅を変えながら記号と文字が入れ替わる
    /// （状態ごとに別のボタンを差し替えると、同じ位置の同じ形が別物として消えて現れる）。⇧⌘R はツールバー、準備中の ⇧⌘. はキャンセルの丸が持つ。
    private func primaryPill(_ state: SessionState) -> some View {
        let pill: PrimaryPill = switch state {
        case .armed:
            PrimaryPill(glyph: .record, title: model.awaitingStartConfirmation ? "録音を開始" : "今すぐ開始", help: "音声の検知を待たずに録音を開始（⇧⌘R）")
        case .finalizing:
            PrimaryPill(glyph: .stop, title: "録音を終了", help: "自動停止の猶予を待たずに録音を終了", shortcut: KeyboardShortcut(".", modifiers: [.command, .shift]))
        default:
            PrimaryPill(glyph: .stop, title: "停止", help: "録音を停止（⇧⌘.）", shortcut: KeyboardShortcut(".", modifiers: [.command, .shift]))
        }
        return Button {
            if state == .armed { model.startNow() } else { model.stopRecording() }
        } label: {
            HStack(spacing: 8) {
                PillGlyph(kind: pill.glyph, size: 28)
                Text(pill.title)
                    .contentTransition(.opacity)
            }
        }
        .buttonStyle(PillButtonStyle(height: 40))
        .help(pill.help)
        .keyboardShortcut(pill.shortcut)
    }
}

struct MeterLabel: View {
    let title: String
    let feed: LevelFeed
    let tint: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            LevelReadout(title: title, feed: feed)
            LevelMeter(feed: feed, tint: tint)
                .frame(width: 72)
        }
    }
}

/// ライブ字幕（確定行 + 途中経過）。
struct LiveCaptionsPane: View {
    @Environment(AppModel.self) private var model

    private var volatileTracks: [String] {
        model.liveVolatile.keys.sorted().filter { !(model.liveVolatile[$0] ?? "").isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("ライブ字幕", systemImage: "captions.bubble")
                    .font(.headline)
                Spacer()
                Text("\(model.liveLines.count) 行")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.liveLines.isEmpty, volatileTracks.isEmpty {
                            waitingPlaceholder
                        }
                        ForEach(model.liveLines) { line in
                            CaptionRow(track: line.track, start: line.start, text: line.text, isVolatile: false, selfName: model.selfDisplayName)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        ForEach(volatileTracks, id: \.self) { track in
                            CaptionRow(track: track, start: nil, text: model.liveVolatile[track] ?? "", isVolatile: true, selfName: model.selfDisplayName)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                    .animation(.snappy(duration: 0.3), value: model.liveLines.count)
                }
                .onChange(of: model.liveLines.count) { _, _ in withAnimation(.smooth) { proxy.scrollTo("bottom") } }
                .onChange(of: model.liveVolatile) { _, _ in proxy.scrollTo("bottom") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardBackground()
        }
        .padding(.trailing, 8)
    }

    private var waitingPlaceholder: some View {
        VStack(spacing: 10) {
            AnimatedSymbol(systemName: "waveform", pointSize: NSFont.TextStyle.largeTitle.pointSize, color: .secondary, effect: .variableColorReversing)
            Text(model.sessionState == .armed ? "会議アプリの音声を待っています" : "字幕はここに流れます")
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.sessionState == .armed {
                Text("準備中の自分の声は会議に含めません（保存・送信しません）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct CaptionRow: View {
    let track: String
    let start: Double?
    let text: String
    let isVolatile: Bool
    var selfName = "自分"

    private var isMe: Bool { track == TrackMerger.micTrack }
    private var tint: Color { isMe ? SpeakerPalette.me : Palette.periwinkle }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(isMe ? selfName : "会議")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    if let start {
                        Text(TimeFormatting.hms(start))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if isVolatile {
                        // 途中経過の行は話している間ずっと出ている。動きは `AnimatedSymbol` に任せる
                        AnimatedSymbol(systemName: "ellipsis", pointSize: NSFont.TextStyle.caption2.pointSize, color: Color(nsColor: .tertiaryLabelColor), effect: .variableColor)
                    }
                }
                Text(text)
                    .foregroundStyle(isVolatile ? .secondary : .primary)
                    .italic(isVolatile)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 自分用メモ（800 ms デバウンスで保存）。
struct NotesPane: View {
    @Binding var notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("メモ", systemImage: "note.text")
                .font(.headline)
            ZStack(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("会議中に気づいたことを書き留めておけます")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 13)
                        .padding(.leading, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $notes)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardBackground()
        }
        .padding(.leading, 8)
    }
}

/// 参加者に録音を知らせる文面をコピーする（SPEC §12）。押すと少しの間「コピーしました」に変わる。
struct NoticeCopyButton: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        Button {
            RecordingNotice.copy(model.settings.resolvedRecordingNotice)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "コピーしました" : "告知文をコピー", systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .help("参加者に録音を知らせる文面をコピーします: \(model.settings.resolvedRecordingNotice)")
    }
}

enum RecordingNotice {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
