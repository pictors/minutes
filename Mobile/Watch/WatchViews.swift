import MinutesKit
import SwiftUI

/// Watch の最初の画面: 録音のボタンと、この Watch の録音の一覧。
struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingNotice = false
    @State private var startError: String?
    @State private var starting = false

    var body: some View {
        // 録音中は一覧の代わりに録音の画面を出す（全画面のシートは watchOS が閉じるボタンを付け、録音したまま画面だけ消せてしまう）
        Group {
            if model.recorder.isActive {
                WatchRecordingView()
            } else {
                list
            }
        }
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
            List {
                Section {
                    Button {
                        start()
                    } label: {
                        Label("録音", systemImage: "record.circle")
                            .font(.headline)
                            .foregroundStyle(.red)
                    }
                    .disabled(starting)
                    if !model.isSignedIn && CloudEnvironment.uploadsAllowed {
                        Text("iPhone の Minutes でログインすると、録音を送れます")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let startError {
                        Text(startError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                if !model.recordings.isEmpty {
                    Section("この Watch の録音") {
                        ForEach(model.recordings, id: \.clientId) { upload in
                            NavigationLink(value: upload.clientId) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(upload.title ?? Formatting.meetingDate(upload.startedAt))
                                        .font(.headline)
                                        .lineLimit(2)
                                    if let duration = upload.durationSeconds {
                                        Text(Formatting.duration(duration))
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(model.status(upload))
                                        .font(.footnote)
                                        .foregroundStyle(upload.lastError != nil ? .red : .secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Minutes")
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

/// 最初の録音の前に一度だけ: 参加者への告知と、音声の送り先（ガイドライン 2.5.14）。
struct WatchNoticeView: View {
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("録音の前に")
                    .font(.headline)
                Text("録音することを参加者に伝え、了承を得てください。")
                Text("音声は Pictors のサーバーに送り、文字起こしと議事録を作ります。音声は 30 日で消えます。")
                    .foregroundStyle(.secondary)
                Button("わかりました", action: onAccept)
                    .buttonStyle(.borderedProminent)
            }
            .font(.footnote)
        }
    }
}

/// 録音中の画面。録音していることがはっきり分かるようにする。手首を下ろしても録り続ける（前面で始めた録音）。
struct WatchRecordingView: View {
    @Environment(WatchModel.self) private var model
    @State private var confirmingStop = false

    var body: some View {
        let recorder = model.recorder
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle()
                    .fill(recorder.phase == .recording ? .red : .orange)
                    .frame(width: 8, height: 8)
                Text(recorder.phase == .recording ? "録音中" : "止まっています")
                    .font(.footnote.bold())
                    .foregroundStyle(recorder.phase == .recording ? .red : .orange)
            }
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                Text(Formatting.clock(recorder.elapsed(at: context.date)))
                    .font(.system(size: 36, weight: .light, design: .rounded).monospacedDigit())
            }
            if let notice = recorder.notice {
                Text(notice)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
            }
            if recorder.phase == .interrupted {
                Button("再開") { recorder.resume() }
            }
            Button(role: .destructive) {
                confirmingStop = true
            } label: {
                Label("止める", systemImage: "stop.fill")
            }
            .tint(.red)
        }
        .confirmationDialog("録音を止めますか？", isPresented: $confirmingStop) {
            Button("止めて送る", role: .destructive) { recorder.stop() }
            Button("続ける", role: .cancel) {}
        }
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
            List {
                Section {
                    Text(Formatting.meetingDate(upload.startedAt))
                    if let duration = upload.durationSeconds {
                        Text(Formatting.duration(duration))
                    }
                    Text(model.status(upload))
                        .font(.footnote)
                        .foregroundStyle(upload.lastError != nil ? .red : .secondary)
                    if !upload.gaps.isEmpty {
                        Text("録れていない時間が \(upload.gaps.count) か所あります")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        if player.isPlaying { player.stop() } else { player.play(model.runURLs(upload)) }
                    } label: {
                        Label(player.isPlaying ? "止める" : "再生", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                    }
                    .disabled(model.runURLs(upload).isEmpty || upload.clientId == model.recorder.clientId)
                    if upload.lastError != nil {
                        Button("もう一度送る") { model.retry(upload) }
                    }
                    if let deleteError {
                        Text(deleteError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("消す", systemImage: "trash")
                    }
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
