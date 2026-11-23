import MinutesKit
import SwiftUI

/// 会議の一覧（この端末の録音と、サーバーの録音）と、録音の始まり。
struct MeetingListView: View {
    @Environment(PhoneModel.self) private var model
    @State private var showingNewMeeting = false
    @State private var showingNotice = false
    @State private var showingAccount = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let banner = model.banner {
                    Text(banner)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                if !CloudEnvironment.uploadsAllowed {
                    Label("シミュレータからは本番に録音を送りません", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.meetings) { item in
                    NavigationLink(value: item.id) {
                        MeetingRow(item: item, recordingClientId: model.recorder.clientId)
                    }
                }
                if model.meetings.isEmpty && !model.isRefreshing {
                    ContentUnavailableView("会議はまだありません", systemImage: "waveform",
                                           description: Text("下の「録音」から始めると、終わったあとに議事録ができます。"))
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("会議")
            .navigationDestination(for: String.self) { id in
                MeetingDetailView(clientId: id)
            }
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAccount = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("アカウント")
                }
            }
            .safeAreaInset(edge: .bottom) {
                RecordButton {
                    if model.noticeAccepted {
                        showingNewMeeting = true
                    } else {
                        showingNotice = true
                    }
                }
                .padding(.bottom, 8)
            }
            .sheet(isPresented: $showingNotice) {
                RecordingNoticeView {
                    model.noticeAccepted = true
                    showingNotice = false
                    showingNewMeeting = true
                }
            }
            .sheet(isPresented: $showingNewMeeting) {
                NewMeetingView()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingAccount) {
                AccountView()
            }
            .fullScreenCover(isPresented: Binding(get: { model.recorder.isActive }, set: { _ in })) {
                RecordingView()
            }
        }
    }
}

private struct MeetingRow: View {
    let item: MeetingItem
    let recordingClientId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title ?? "無題の会議")
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(Formatting.meetingDate(item.startedAt))
                if let duration = item.durationSeconds {
                    Text(Formatting.duration(duration))
                }
                if item.server?.source == "watch" || item.local?.source == "watch" {
                    Image(systemName: "applewatch")
                        .accessibilityLabel("Watch で録音")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            let status = Formatting.status(item, recordingClientId: recordingClientId)
            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(item.local?.lastError != nil || item.server?.status == "failed" ? .red : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct RecordButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("録音", systemImage: "record.circle")
                .font(.title3.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .padding(.horizontal)
    }
}

/// 録音を始める前: 会議の名前（任意）と、参加者への告知の念押し。
private struct NewMeetingView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var message: String?
    @State private var starting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("会議の名前（なくてもよい）", text: $title)
                } footer: {
                    Text("録音することを、参加者に伝えてから始めてください。")
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        start()
                    } label: {
                        Label("録音を始める", systemImage: "record.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(starting)
                }
            }
            .navigationTitle("新しい会議")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
            }
        }
    }

    private func start() {
        starting = true
        Task {
            defer { starting = false }
            do {
                try await model.recorder.start(title: title)
                dismiss()
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
