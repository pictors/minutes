import MinutesKit
import SwiftUI

/// 会議の一覧（日付ごと。この iPhone の録音と、サーバーの録音）と、録音の始まり。
struct MeetingListView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingNewMeeting = false
    @State private var showingNotice = false
    @State private var showingAccount = false
    @State private var path: [String] = []

    private struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let items: [MeetingItem]
    }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: model.meetings) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { DayGroup(id: $0, title: Formatting.dayTitle($0), items: byDay[$0] ?? []) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    // 上端: ロゴ（Mac のパネルと同じ組み）と、アカウント
                    HStack {
                        MinutesBrandLockup(height: 22)
                        Spacer()
                        Button {
                            showingAccount = true
                        } label: {
                            Image(systemName: "person.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, height: 38)
                                .background(Surface.raised, in: .circle)
                        }
                        .buttonStyle(CardPressStyle())
                        .accessibilityLabel("アカウント")
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 2)
                    if let banner = model.banner {
                        Label(banner, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Palette.amber)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardBackground()
                    }
                    if !CloudEnvironment.uploadsAllowed {
                        Label("シミュレータからは本番に録音を送りません", systemImage: "internaldrive")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                            ForEach(group.items) { item in
                                NavigationLink(value: item.id) {
                                    MeetingCard(item: item, recordingClientId: model.recorder.clientId)
                                }
                                .buttonStyle(CardPressStyle())
                                .transition(Motion.content(reduceMotion: reduceMotion))
                            }
                        }
                    }
                    if model.meetings.isEmpty && !model.isRefreshing {
                        EmptyMeetings()
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 110)
                .animation(Motion.layout, value: model.meetings.map(\.id))
            }
            .background(Surface.page.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                MeetingDetailView(clientId: id)
            }
            .refreshable { await model.refresh() }
            .safeAreaInset(edge: .bottom) {
                Button {
                    if model.noticeAccepted {
                        showingNewMeeting = true
                    } else {
                        showingNotice = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        PillGlyph(kind: .record, size: 36)
                        Text("録音")
                    }
                }
                .buttonStyle(PillButtonStyle(height: 60, floating: true))
                .sensoryFeedback(.impact(weight: .light), trigger: showingNewMeeting)
                .padding(.bottom, 10)
                // シートの下に透けないように、シートが出ているあいだは隠す
                .opacity(showingNewMeeting || showingNotice ? 0 : 1)
                .animation(Motion.press, value: showingNewMeeting || showingNotice)
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
                    .presentationDetents([.height(300)])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Surface.card)
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

/// 一覧の 1 行: 題名、始まった時刻と長さ、状態。
private struct MeetingCard: View {
    let item: MeetingItem
    let recordingClientId: String?

    var body: some View {
        let state = Formatting.state(item, recordingClientId: recordingClientId)
        let fromWatch = item.server?.source == "watch" || item.local?.source == "watch"
        HStack(alignment: .top, spacing: 12) {
            TintedTile(systemImage: state?.isError == true ? "exclamationmark.triangle.fill" : (fromWatch ? "applewatch" : "waveform"),
                       tint: state?.isError == true ? Palette.rose : (item.isDone ? Palette.periwinkle : (state?.tint ?? Palette.periwinkle)), size: 40)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title ?? "無題の会議")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(Formatting.timeOfDay(item.startedAt))
                    if let duration = item.durationSeconds {
                        Text("·")
                        Text(Formatting.duration(duration))
                    }
                    if let count = item.server?.speakerCount, count > 0 {
                        Text("·")
                        Label("\(count)", systemImage: "person.2.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                if let state {
                    StatusPill(text: state.text, tint: state.tint, systemImage: state.systemImage, isBusy: state.isBusy)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .contentShape(.rect(cornerRadius: 20, style: .continuous))
    }
}

/// 会議がないとき。Mac のアプリの空の表示と同じく、マークは色を付けず灰色で小さく、ことばは「まだありません」にする
/// （ブランドを大きく見せるのはログインの画面だけ）。どの会議が並ぶかも書く（Mac で録った会議は、まだ iPhone には出ない）。
private struct EmptyMeetings: View {
    var body: some View {
        VStack(spacing: 10) {
            MinutesMark(height: 34, color: .secondary)
                .opacity(0.7)
                .padding(.bottom, 6)
            Text("会議はまだありません")
                .font(.title3.weight(.semibold))
            Text("iPhone と Apple Watch で録った会議が、\nここに並びます。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 80)
    }
}

/// 録音を始める前: 会議の名前（任意）と、参加者への告知の念押し。
private struct NewMeetingView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var message: String?
    @State private var starting = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新しい会議")
                .font(.title2.bold())
            TextField("会議の名前（なくてもよい）", text: $title)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit { start() }
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(Surface.raised, in: .rect(cornerRadius: 14, style: .continuous))
            Label("録音することを、参加者に伝えてから始めてください。", systemImage: "person.2.wave.2")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.rose)
            }
            Spacer(minLength: 0)
            Button {
                start()
            } label: {
                HStack(spacing: 12) {
                    PillGlyph(kind: .record, size: 34)
                    Text("録音を始める")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(height: 58))
            .disabled(starting)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 12)
    }

    private func start() {
        guard !starting else { return }
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
