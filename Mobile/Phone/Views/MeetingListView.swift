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
    @State private var filter = MeetingListFilter()
    @FocusState private var searching: Bool
    /// 行を長押しして選んだ操作の対象（名前を変える・リンクで共有・消す）
    @State private var renameTarget: MeetingItem?
    @State private var titleDraft = ""
    @State private var shareTarget: MeetingItem?
    @State private var deleteTarget: MeetingItem?
    @State private var rowError: String?

    private struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let items: [MeetingItem]
    }

    private static func groups(_ items: [MeetingItem]) -> [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { DayGroup(id: $0, title: Formatting.dayTitle($0), items: byDay[$0] ?? []) }
    }

    var body: some View {
        // 絞り込み・検索に当てはまる会議（何も絞っていなければ全部）
        let shown = filter.apply(model.meetings, recordingClientId: model.recorder.clientId)
        let groups = Self.groups(shown)
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
                    // 議事録を待つ会議ができたら、通知を受け取るかを聞く（SPEC §5.7）
                    if NotificationPromptCard.shouldShow(push: PushNotifications.shared, model: model) {
                        NotificationPromptCard(push: PushNotifications.shared)
                            .transition(.opacity)
                    }
                    if !model.meetings.isEmpty {
                        MeetingFilterBar(filter: $filter, meetings: model.meetings, recordingClientId: model.recorder.clientId, searching: $searching)
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
                                // 長押しで、開かずに名前を変える・共有する・消す（会議の画面の「⋯」と同じ決まり）
                                .contextMenu { rowMenu(item) }
                                // 確認は長押しした行から出す（画面全体に付けると、関係のない場所から出る）
                                .confirmationDialog("この会議を消しますか？", isPresented: deleteBinding(item), titleVisibility: .visible) {
                                    Button("消す", role: .destructive) { delete(item) }
                                } message: {
                                    Text("音声・文字起こし・議事録を、この iPhone とサーバーから消します。元に戻せません。")
                                }
                                .transition(Motion.content(reduceMotion: reduceMotion))
                            }
                        }
                    }
                    if model.meetings.isEmpty {
                        // 「まだありません」は一覧を一度読めてから出し、読み直しのあいだも出したままにする（引き下げにはシステムの印が出る。
                        // アカウントのシートは一覧を隠している）。読めるまで（起動・ログインの直後）は読み込みの印を出す。
                        // 最初の読み込みが失敗したら上の知らせだけにする（分からないのに「ない」と言わない）
                        if model.meetingsLoaded {
                            EmptyMeetings()
                                .transition(.opacity)
                        } else if model.banner == nil {
                            LoadingMeetings()
                                .transition(.opacity)
                        }
                    } else if shown.isEmpty {
                        NoMatchingMeetings(filter: filter) {
                            filter = MeetingListFilter()
                            searching = false
                        }
                        .transition(.opacity)
                    }
                }
                // 通知の誘いが消える（受け取る・あとで）ときもフェードにする
                .animation(Motion.layout, value: NotificationPromptCard.shouldShow(push: PushNotifications.shared, model: model))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 110)
                .animation(Motion.layout, value: shown.map(\.id))
                // 読み込みの印 → 「まだありません」・知らせの入れ替わりもフェードにする（会議の ID は変わらないので、上だけでは動きが付かない）
                .animation(Motion.layout, value: model.meetingsLoaded)
                .animation(Motion.layout, value: model.banner == nil)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.page.ignoresSafeArea())
            // 送った一覧が時刻やダイナミックアイランドに重ならないように、上の安全域を地の色で覆い、その下を少しぼかす（ログインの画面と同じ）
            .overlay(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).background(Surface.page)
                    LinearGradient(colors: [Surface.page, Surface.page.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 16)
                }
                .allowsHitTesting(false)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                MeetingDetailView(clientId: id)
            }
            // 押した通知（議事録ができた・処理できなかった）の会議を開く
            .modifier(OpensNotifiedMeeting(path: $path))
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
                // シートの下に透けないように、シートが出ているあいだは隠す。検索の入力中も隠す（キーボードの上に浮いて一覧を覆う）
                .opacity(showingNewMeeting || showingNotice || searching ? 0 : 1)
                .allowsHitTesting(!searching)
                .animation(Motion.press, value: showingNewMeeting || showingNotice || searching)
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
            // 録音が始まったら、この画面のシート・アラートの状態を戻す（ウィジェットなどから始めたときは QuickRecordHandler が UIKit で閉じるので、
            // SwiftUI の状態が「開いている」のまま残り、録音のあとでまた出ないようにする）
            .onChange(of: model.recorder.isActive) { _, active in
                guard active else { return }
                showingNotice = false
                showingAccount = false
                renameTarget = nil
                shareTarget = nil
                deleteTarget = nil
                rowError = nil
                searching = false
            }
            .fullScreenCover(isPresented: Binding(get: { model.recorder.isActive }, set: { _ in })) {
                RecordingView()
            }
            .sheet(item: $shareTarget) { item in
                if let server = item.shareableRecording {
                    ShareLinksView(recordingID: server.id, hasSummary: server.summaryError == nil)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                        .presentationBackground(Surface.page)
                }
            }
            .alert("会議の名前", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("会議の名前", text: $titleDraft)
                Button("保存") { rename() }
                    .disabled(renameTarget?.allowsEmptyTitle == false && titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("やめる", role: .cancel) { renameTarget = nil }
            }
            .alert("操作できませんでした", isPresented: Binding(get: { rowError != nil }, set: { if !$0 { rowError = nil } })) {
                Button("閉じる", role: .cancel) {}
            } message: {
                Text(rowError ?? "")
            }
        }
    }

    /// 行の長押しの操作（会議の画面の「⋯」と同じ決まり: Mac の会議は名前を変える・共有だけ（消すのは Mac）、録音中の会議は消せない）
    @ViewBuilder
    private func rowMenu(_ item: MeetingItem) -> some View {
        if item.canRename {
            Button {
                titleDraft = item.title ?? ""
                renameTarget = item
            } label: {
                Label("名前を変える", systemImage: "pencil")
            }
        }
        if item.shareableRecording != nil {
            Button {
                shareTarget = item
            } label: {
                Label("リンクで共有…", systemImage: "link")
            }
        }
        if item.canDelete {
            Button(role: .destructive) {
                deleteTarget = item
            } label: {
                Label("会議を消す", systemImage: "trash")
            }
            // アプリ全体の色（青紫）が、メニューの消す記号にも付いてしまうので、文字と同じ赤にする
            .tint(.red)
            .disabled(item.id == model.recorder.clientId)
        }
    }

    private func deleteBinding(_ item: MeetingItem) -> Binding<Bool> {
        Binding(get: { deleteTarget?.id == item.id }, set: { if !$0 { deleteTarget = nil } })
    }

    private func rename() {
        guard let item = renameTarget else { return }
        let title = titleDraft
        renameTarget = nil
        Task {
            do {
                try await model.rename(item, title: title)
            } catch {
                rowError = "名前を変えられませんでした（\(error.localizedDescription)）"
            }
        }
    }

    private func delete(_ item: MeetingItem) {
        deleteTarget = nil
        Task {
            do {
                try await model.delete(item)
            } catch {
                rowError = "消せませんでした（\(error.localizedDescription)）"
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
        let tile = item.isMacMeeting ? "laptopcomputer" : (item.server?.source == "watch" || item.local?.source == "watch") ? "applewatch" : "waveform"
        HStack(alignment: .top, spacing: 12) {
            TintedTile(systemImage: state?.isError == true ? "exclamationmark.triangle.fill" : tile,
                       tint: state?.isError == true ? Palette.rose : (item.isDone ? Palette.periwinkle : (state?.tint ?? Palette.periwinkle)), size: 40)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title ?? MeetingItem.untitled)
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

/// 検索の欄と、絞り込みのチップ（範囲: すべて・今日・今週・処理中・失敗。録った機器: 2 種類以上あるときだけ）。
/// 範囲は 1 つを選び、機器はもう一度押すと外れる。
private struct MeetingFilterBar: View {
    @Binding var filter: MeetingListFilter
    let meetings: [MeetingItem]
    let recordingClientId: String?
    var searching: FocusState<Bool>.Binding

    private var origins: [MeetingOrigin] {
        let present = Set(meetings.map(\.origin))
        // 1 種類しかなければ出さない（選んでも変わらない）。選んだままその機器の会議がなくなったら、外せるように残す
        guard present.count > 1 || filter.origin != nil else { return [] }
        return MeetingOrigin.allCases.filter { present.contains($0) || $0 == filter.origin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("会議の名前で検索", text: $filter.query)
                    .focused(searching)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !filter.query.isEmpty {
                    Button {
                        filter.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 30, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("検索の文字を消す")
                    .transition(.opacity)
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, filter.query.isEmpty ? 14 : 6)
            .frame(height: 44)
            .background(Surface.card, in: .capsule)
            .animation(Motion.press, value: filter.query.isEmpty)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(MeetingListFilter.Scope.allCases) { scope in
                        FilterChip(title: scope.title, count: count(scope), isOn: filter.scope == scope) {
                            filter.scope = scope
                        }
                    }
                    if !origins.isEmpty {
                        Rectangle()
                            .fill(Surface.hairline)
                            .frame(width: 1, height: 18)
                            .padding(.horizontal, 2)
                        ForEach(origins) { origin in
                            FilterChip(title: origin.name, systemImage: origin.systemImage, isOn: filter.origin == origin) {
                                filter.origin = filter.origin == origin ? nil : origin
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            // チップの並びは画面の端まで流す（一覧の左右の余白の外へ）
            .padding(.horizontal, -16)
        }
        .sensoryFeedback(.selection, trigger: filter.scope)
        .sensoryFeedback(.selection, trigger: filter.origin)
    }

    /// 処理中・失敗は数を添える（あるときだけ）
    private func count(_ scope: MeetingListFilter.Scope) -> Int? {
        guard scope == .processing || scope == .failed else { return nil }
        return MeetingListFilter.count(scope, in: meetings, recordingClientId: recordingClientId)
    }
}

private struct FilterChip: View {
    let title: String
    var systemImage: String?
    var count: Int?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                }
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .opacity(0.65)
                        .contentTransition(.numericText())
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isOn ? Palette.periwinkle : Color.secondary)
            .padding(.horizontal, 13)
            .frame(height: 36)
            .background(isOn ? Palette.periwinkle.opacity(0.16) : Surface.card, in: .capsule)
            .contentShape(.capsule)
            .animation(Motion.press, value: isOn)
        }
        .buttonStyle(CardPressStyle())
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// 絞り込み・検索に当てはまる会議がないとき。検索が会議の名前だけに当たることも書く。
private struct NoMatchingMeetings: View {
    let filter: MeetingListFilter
    let reset: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filter.terms.isEmpty ? "line.3.horizontal.decrease" : "magnifyingglass")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(0.7)
                .padding(.bottom, 6)
            Text("当てはまる会議がありません")
                .font(.title3.weight(.semibold))
            if !filter.terms.isEmpty {
                Text("検索は会議の名前に当たります。全文と議事録の中身は、まだ検索できません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("絞り込みを解く", action: reset)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 56)
    }
}

/// 一覧をまだ一度も読めていないとき（起動・ログインの直後）。議事録・リンクの読み込みと同じ形。
/// 読み込みが長いときだけ出す（1 秒待つ）。ふつうの回線では 1 秒より前に読み終えるので、出ない。
/// 待ちが短いと、出たカードがすぐ消えてちらつく（0.4 秒待ちのとき、0.6 秒の読み込みで一瞬だけ出て消えた）。
private struct LoadingMeetings: View {
    @State private var visible = false

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("会議を読んでいます").foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .opacity(visible ? 1 : 0)
        .accessibilityHidden(!visible)
        .task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            withAnimation(Motion.layout) { visible = true }
        }
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
            Text("iPhone と Apple Watch で録った会議が、ここに並びます。\nMac の会議は、Mac の設定で同期を入れると出ます。")
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
