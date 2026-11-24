import MinutesKit
import SwiftUI

/// Watch の最初の画面: 録音のボタンと、この Watch の録音の一覧。
struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingNotice = false
    @State private var startError: String?
    @State private var starting = false

    var body: some View {
        // 録音中は一覧の代わりに録音の画面を出す（全画面のシートは watchOS が閉じるボタンを付け、録音したまま画面だけ消せてしまう）
        ZStack {
            if model.recorder.isActive {
                WatchRecordingView()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
            } else {
                list
                    .transition(.opacity)
            }
        }
        .animation(Motion.layout, value: model.recorder.isActive)
        .tint(Palette.periwinkle)
        .sensoryFeedback(trigger: model.recorder.isActive) { _, active in active ? .start : .stop }
        .sheet(isPresented: $showingNotice) {
            WatchNoticeView {
                model.noticeAccepted = true
                showingNotice = false
                start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.becameActive() }
        }
    }

    private var list: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    MinutesBrandLockup(height: 13)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                    Button {
                        start()
                    } label: {
                        VStack(spacing: 6) {
                            PillGlyph(kind: .record, size: 64)
                            Text("録音")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(CardPressStyle())
                    .disabled(starting)
                    .accessibilityLabel("録音を始める")

                    if !model.isSignedIn && CloudEnvironment.uploadsAllowed {
                        Label("iPhone の Minutes でログインすると、録音を送れます", systemImage: "iphone")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardBackground(cornerRadius: 14)
                    }
                    if let startError {
                        Text(startError)
                            .font(.footnote)
                            .foregroundStyle(Palette.rose)
                    }
                    if !model.recordings.isEmpty {
                        Text("この Watch の録音")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                            .padding(.leading, 4)
                        ForEach(model.recordings, id: \.clientId) { upload in
                            NavigationLink(value: upload.clientId) {
                                WatchRecordingRow(upload: upload)
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .navigationDestination(for: String.self) { clientId in
                WatchRecordingDetailView(clientId: clientId)
            }
        }
    }

    private func start() {
        guard model.noticeAccepted else {
            showingNotice = true
            return
        }
        starting = true
        Task {
            defer { starting = false }
            do {
                try await model.recorder.start(title: nil)
                startError = nil
            } catch {
                startError = error.localizedDescription
            }
        }
    }
}

private struct WatchRecordingRow: View {
    let upload: MinutesCloudUpload
    @Environment(WatchModel.self) private var model

    var body: some View {
        let state = model.state(upload)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(upload.title ?? Formatting.dayTitle(upload.startedAt))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(Formatting.timeOfDay(upload.startedAt))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let duration = upload.durationSeconds {
                    Text(Formatting.duration(duration))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Label(state.short, systemImage: state.systemImage)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(state.tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: state.isBusy)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 14)
    }
}

/// 最初の録音の前に一度だけ: 参加者への告知と、音声の送り先（ガイドライン 2.5.14）。
struct WatchNoticeView: View {
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("録音の前に")
                    .font(.headline)
                Label("録音することを参加者に伝え、了承を得てください。", systemImage: "person.2.wave.2.fill")
                Label("音声は Minutes のサーバーに送り、文字起こしと議事録を作ります。音声は 30 日で消えます。", systemImage: "icloud.and.arrow.up.fill")
                    .foregroundStyle(.secondary)
                Button("わかりました", action: onAccept)
                    .buttonStyle(FilledPillButtonStyle(height: 40))
                    .padding(.top, 4)
            }
            .font(.footnote)
        }
    }
}

/// 録音中の画面。録音していることがはっきり分かるようにする。手首を下ろしても録り続ける（前面で始めた録音）。
struct WatchRecordingView: View {
    @Environment(WatchModel.self) private var model
    @State private var confirmingStop = false
    @State private var history = LevelHistory()

    var body: some View {
        let recorder = model.recorder
        let recording = recorder.phase == .recording
        VStack(spacing: 4) {
            StatusPill(text: recording ? "録音中" : "止まっています", tint: recording ? Palette.record : Palette.amber,
                       systemImage: recording ? "record.circle.fill" : "pause.circle.fill", isBusy: recording)
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                BigTimerText(seconds: recorder.elapsed(at: context.date), size: 46, isDimmed: !recording)
            }
            LevelWaveform(levels: history.levels, tint: recording ? Palette.record : .secondary, barWidth: 2, spacing: 2)
                .frame(height: 18)
                .padding(.horizontal, 16)
                .opacity(recording ? 1 : 0.35)
            if let notice = recorder.notice {
                Text(notice)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.amber)
                    .lineLimit(3)
            }
            Spacer(minLength: 2)
            if recorder.phase == .interrupted {
                Button {
                    recorder.resume()
                } label: {
                    HStack(spacing: 8) {
                        PillGlyph(kind: .resume, size: 24)
                        Text("再開")
                    }
                }
                .buttonStyle(PillButtonStyle(height: 38))
            }
            Button {
                confirmingStop = true
            } label: {
                HStack(spacing: 8) {
                    PillGlyph(kind: .stop, size: 26)
                    Text("止める")
                }
            }
            .buttonStyle(PillButtonStyle(height: 42))
        }
        .padding(.top, 2)
        .confirmationDialog("録音を止めますか？", isPresented: $confirmingStop) {
            Button("止めて送る", role: .destructive) { recorder.stop() }
            Button("続ける", role: .cancel) {}
        }
        .onAppear { history.start(capacity: 48) { model.recorder.phase == .recording ? model.recorder.level : 0 } }
        .onDisappear { history.stop() }
    }
}

/// 録音の詳細: 再生・消す・送り直す。
struct WatchRecordingDetailView: View {
    let clientId: String
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var player = RunPlayback()
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        if let upload = model.recording(clientId) {
            let state = model.state(upload)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Formatting.dayTitle(upload.startedAt)) \(Formatting.timeOfDay(upload.startedAt))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let duration = upload.durationSeconds {
                            DurationText(seconds: duration, size: 26)
                        }
                        Label(state.text, systemImage: state.systemImage)
                            .font(.footnote)
                            .foregroundStyle(state.tint)
                            .symbolEffect(.pulse, options: .repeating, isActive: state.isBusy)
                        if !upload.gaps.isEmpty {
                            Text("録れていない時間が \(upload.gaps.count) か所あります")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground(cornerRadius: 14)

                    Button {
                        if player.isPlaying { player.stop() } else { player.play(model.runURLs(upload)) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: player.isPlaying ? "stop.fill" : "play.fill")
                                .contentTransition(.symbolEffect(.replace))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(Palette.periwinkle, in: .circle)
                            Text(player.isPlaying ? "止める" : "再生")
                        }
                    }
                    .buttonStyle(PillButtonStyle(height: 40))
                    .disabled(model.runURLs(upload).isEmpty || upload.clientId == model.recorder.clientId)

                    if upload.lastError != nil {
                        Button("もう一度送る") { model.retry(upload) }
                            .buttonStyle(FilledPillButtonStyle(height: 38))
                    }
                    if let deleteError {
                        Text(deleteError)
                            .font(.footnote)
                            .foregroundStyle(Palette.rose)
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("消す", systemImage: "trash")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Palette.rose)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .disabled(upload.clientId == model.recorder.clientId)
                }
            }
            .confirmationDialog("この録音を消しますか？", isPresented: $confirmingDelete) {
                Button("消す", role: .destructive) {
                    player.stop()
                    Task {
                        do {
                            try await model.delete(upload)
                            dismiss()
                        } catch {
                            deleteError = "サーバーで消せませんでした（\(error.localizedDescription)）。つながってからもう一度消してください"
                        }
                    }
                }
            } message: {
                Text("この Watch とサーバーから消します。元に戻せません。")
            }
            .onDisappear { player.stop() }
        } else {
            Text("録音が見つかりません")
        }
    }
}
