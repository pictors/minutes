import AVFoundation
import MinutesKit
import SwiftUI

/// 会議の議事録（要約・決まったこと・やること・確かめること）、全文、音声。
struct MeetingDetailView: View {
    let clientId: String
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var summary: MinutesSummary?
    @State private var transcript: TranscriptDocument?
    @State private var loadError: String?
    @State private var confirmingDelete = false
    @State private var player = AudioPlayback()

    private var item: MeetingItem? { model.meetings.first { $0.id == clientId } }

    var body: some View {
        List {
            if let item {
                header(item)
                if let summary {
                    summarySections(summary)
                } else if item.isDone, loadError == nil {
                    Section { ProgressView("議事録を読んでいます") }
                }
                if let loadError {
                    Section { Text(loadError).foregroundStyle(.red) }
                }
                audioSection(item)
                if let transcript, !transcript.segments.isEmpty {
                    Section("全文") {
                        ForEach(transcript.segments, id: \.id) { segment in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Formatting.speaker(segment.speaker, in: transcript))  \(Formatting.clock(segment.tStart))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(segment.text)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("会議が見つかりません", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(item?.title ?? "無題の会議")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("会議を消す")
                .disabled(item == nil || item?.id == model.recorder.clientId)
            }
        }
        .confirmationDialog("この会議を消しますか？", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("消す", role: .destructive) { delete() }
        } message: {
            Text("音声・文字起こし・議事録を、この iPhone とサーバーから消します。元に戻せません。")
        }
        .task(id: item?.server?.status) { await load() }
        .refreshable {
            if let id = item?.server?.id { await model.reloadServerRecording(id: id) }
            await load()
        }
        .onDisappear { player.stop() }
    }

    @ViewBuilder
    private func header(_ item: MeetingItem) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(Formatting.meetingDate(item.startedAt))
                    .foregroundStyle(.secondary)
                if let duration = item.durationSeconds {
                    Text(Formatting.duration(duration)).foregroundStyle(.secondary)
                }
                let status = Formatting.status(item, recordingClientId: model.recorder.clientId)
                if !status.isEmpty {
                    Text(status)
                        .foregroundStyle(item.local?.lastError != nil || item.server?.status == "failed" ? .red : .orange)
                }
                if let gaps = item.local?.gaps, !gaps.isEmpty {
                    Text("録れていない時間が \(gaps.count) か所あります（電話・Siri などで止まった時間）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let local = item.local, !local.completed, local.lastError != nil {
                Button("もう一度送る") { model.retryUpload(item) }
            }
        }
    }

    @ViewBuilder
    private func summarySections(_ summary: MinutesSummary) -> some View {
        Section("要約") {
            Text(Self.markdown(summary.summaryMd))
                .textSelection(.enabled)
        }
        if !summary.decisions.isEmpty {
            Section("決まったこと") {
                ForEach(Array(summary.decisions.enumerated()), id: \.offset) { _, decision in
                    Text(decision.text)
                }
            }
        }
        if !summary.actionItems.isEmpty {
            Section("やること") {
                ForEach(Array(summary.actionItems.enumerated()), id: \.offset) { _, action in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(action.text)
                        HStack(spacing: 8) {
                            Text(Formatting.speaker(action.owner, in: transcript))
                            if let due = action.due { Text("期限 \(due)") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !summary.openQuestions.isEmpty {
            Section("確かめること") {
                ForEach(Array(summary.openQuestions.enumerated()), id: \.offset) { _, question in
                    Text(question.text)
                }
            }
        }
    }

    @ViewBuilder
    private func audioSection(_ item: MeetingItem) -> some View {
        let canPlayServer = item.server?.status == "done" && item.server?.audioDeleted != true
        if canPlayServer || model.localAudioURL(item) != nil {
            Section("音声") {
                Button {
                    toggle(item)
                } label: {
                    Label(player.isPlaying ? "止める" : (player.isLoading ? "読み込んでいます" : "再生"),
                          systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(player.isLoading)
                if let error = player.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let expires = item.server?.audioExpiresAt, item.server?.audioDeleted != true {
                    Text("サーバーの音声は \(Formatting.meetingDate(expires)) に消えます")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toggle(_ item: MeetingItem) {
        if player.isPlaying {
            player.pause()
            return
        }
        if let server = item.server, server.status == "done", server.audioDeleted != true {
            player.play(remote: server.id, client: model.client)
        } else if let url = model.localAudioURL(item) {
            player.play(file: url)
        }
    }

    private func load() async {
        guard let server = item?.server, server.status == "done" else { return }
        do {
            async let summary = server.summaryError == nil ? model.client.summary(recordingID: server.id) : nil
            async let transcript = model.client.transcript(recordingID: server.id)
            self.transcript = try await transcript
            self.summary = try await summary
            loadError = nil
        } catch {
            loadError = "議事録を読めませんでした（\(error.localizedDescription)）"
        }
    }

    private func delete() {
        guard let item else { return }
        Task {
            do {
                try await model.delete(item)
                dismiss()
            } catch {
                loadError = "消せませんでした（\(error.localizedDescription)）"
            }
        }
    }

    /// 要約の Markdown（見出し・箇条書きは行のまま、太字などは効かせる）
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// 音声の再生（サーバーの音声は一度ファイルに取ってから再生する）。
@MainActor
@Observable
final class AudioPlayback {
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var error: String?
    private var player: AVAudioPlayer?
    private var loadedID: String?

    func play(file url: URL) {
        do {
            if player?.url != url { player = try AVAudioPlayer(contentsOf: url) }
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            player?.play()
            isPlaying = true
            error = nil
        } catch {
            self.error = "再生できません（\(error.localizedDescription)）"
        }
    }

    func play(remote id: String, client: MinutesCloudClient) {
        let url = FileManager.default.temporaryDirectory.appending(path: "minutes-audio-\(id).aac")
        if loadedID == id, FileManager.default.fileExists(atPath: url.path) {
            play(file: url)
            return
        }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await client.downloadAudio(recordingID: id, to: url)
                loadedID = id
                play(file: url)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }
}
