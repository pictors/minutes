import MinutesKit
import SwiftUI
import UIKit

/// 閲覧用のリンク（P7）: リンクを知っている人が、ログインせずにブラウザで議事録を読める。
/// 既定は要約だけ・30 日。全文は選んだときだけ入れる。音声は共有しない。取り消すと、すぐに読めなくなる。
struct ShareLinksView: View {
    let recordingID: String
    /// 要約があるか（ないときは全文を入れたリンクだけ作れる）
    let hasSummary: Bool
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var includeTranscript = false
    @State private var expiryDays = MinutesCloudShare.defaultExpiryDays
    @State private var shares: [MinutesCloudShare] = []
    @State private var loaded = false
    @State private var working = false
    @State private var message: String?
    @State private var copiedID: String?
    @State private var newShareID: String?
    @State private var revoking: MinutesCloudShare?
    /// 作ろうとして、要約がないと分かった（一覧から開いたときは、要約があるかまだ分からない）
    @State private var summaryMissing = false

    private var summaryAvailable: Bool { hasSummary && !summaryMissing }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !loaded {
                        // 読み終えるまでは作る欄を出さない（使えるリンクがあると、あとから上に入って欄が下へ動く）
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("リンクを読んでいます").foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardBackground()
                    } else {
                        // 使えるリンクを先に出す（半分の高さのシートでも、作ったリンクと「送る」「コピー」がすぐ見える）
                        if !shares.isEmpty {
                            linksCard
                                .transition(Motion.content(reduceMotion: reduceMotion))
                        }
                        if let message {
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(Palette.rose)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .cardBackground()
                        }
                        createCard
                    }
                    Text("リンクを知っている人は、だれでもログインせずに読めます。送る相手に気をつけてください。期限が過ぎるか取り消すと、読めなくなります。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(Motion.layout, value: shares.map(\.id))
                .animation(Motion.layout, value: loaded)
            }
            .background(Surface.page.ignoresSafeArea())
            .navigationTitle("リンクで共有")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    // MARK: 作る

    private var createCard: some View {
        SectionCard("新しいリンク", systemImage: "link", tint: Palette.periwinkle) {
            VStack(alignment: .leading, spacing: 14) {
                Text("議事録（要約・決まったこと・やること・確かめること）を、ブラウザで読めるリンクにします。音声は共有しません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(isOn: summaryAvailable ? $includeTranscript : .constant(true)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("全文も入れる")
                        Text(summaryAvailable ? "発言をすべて、話者の名前つきで見せます" : "この会議には要約がないので、全文を共有します")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Palette.periwinkle)
                .disabled(!summaryAvailable)
                HStack {
                    Text("期限")
                    Spacer()
                    SegmentedTabs(tabs: MinutesCloudShare.expiryChoices, selection: $expiryDays, height: 34) { "\($0) 日" }
                        .frame(maxWidth: 220)
                        .sensoryFeedback(.selection, trigger: expiryDays)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("期限")
                }
                Button {
                    create()
                } label: {
                    if working {
                        ProgressView().tint(.white)
                    } else {
                        Text("リンクを作る")
                    }
                }
                .buttonStyle(FilledPillButtonStyle(height: 48))
                .disabled(working)
            }
        }
    }

    // MARK: 使えるリンク

    private var linksCard: some View {
        SectionCard("使えるリンク", systemImage: "link.circle.fill", count: shares.count, tint: Palette.mint) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shares.enumerated()), id: \.element.id) { index, share in
                    if index > 0 {
                        Rectangle().fill(Surface.hairline).frame(height: 1)
                    }
                    shareRow(share)
                }
            }
        }
    }

    private func shareRow(_ share: MinutesCloudShare) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(share.includeTranscript ? "要約と全文" : "要約だけ")
                            .font(.body.weight(.medium))
                        if share.id == newShareID {
                            StatusPill(text: "作りました", tint: Palette.mint, systemImage: "checkmark.circle.fill")
                        }
                    }
                    Text("\(Self.expiryText(share.expiresAt)) まで読めます")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Text(share.url.absoluteString)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                ShareLink(item: share.url) {
                    Label("送る", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PillButtonStyle(height: 36))
                Button {
                    UIPasteboard.general.url = share.url
                    copiedID = share.id
                } label: {
                    Label(copiedID == share.id ? "コピーしました" : "コピー", systemImage: copiedID == share.id ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PillButtonStyle(height: 36))
                .sensoryFeedback(.success, trigger: copiedID == share.id)
                Spacer(minLength: 0)
                Button(role: .destructive) {
                    revoking = share
                } label: {
                    Text("取り消す")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.rose)
                }
                .buttonStyle(.plain)
                // 確認は押したボタンから出す（画面全体に付けると、関係のない場所から出る）
                .confirmationDialog("このリンクを取り消しますか？", isPresented: revokingBinding(share), titleVisibility: .visible) {
                    Button("取り消す", role: .destructive) { revoke(share) }
                } message: {
                    Text("リンクを開いても、議事録が読めなくなります。元に戻せません。")
                }
            }
        }
        .padding(.vertical, 12)
        .disabled(working)
    }

    private func revokingBinding(_ share: MinutesCloudShare) -> Binding<Bool> {
        Binding(get: { revoking?.id == share.id }, set: { if !$0 { revoking = nil } })
    }

    /// 12月24日（水）
    static func expiryText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
    }

    // MARK: サーバー

    private func load() async {
        do {
            shares = try await model.client.shares(recordingID: recordingID)
            message = nil
        } catch where PhoneModel.isCancellation(error) {
            // シートを閉じた（誤りとして出さない）
        } catch {
            message = Self.describe(error, action: "リンクを読めませんでした")
        }
        loaded = true
    }

    private func create() {
        working = true
        message = nil
        let include = summaryAvailable ? includeTranscript : true
        Task {
            defer { working = false }
            do {
                let share = try await model.client.createShare(recordingID: recordingID, includeTranscript: include, expiresInDays: expiryDays)
                shares.insert(share, at: 0)
                newShareID = share.id
                // 作ったリンクはすぐに貼れるようにしておく
                UIPasteboard.general.url = share.url
                copiedID = share.id
            } catch let error as MinutesCloudError where error.status == 409 && error.code == "no_summary" {
                // 要約がない会議（一覧の長押しから開いたときは、作るまで分からない）。全文を入れるかは選び直してもらう
                withAnimation(Motion.layout) { summaryMissing = true }
                message = "この会議には要約がありません。全文を入れたリンクになります。よければ、もう一度「リンクを作る」を押してください。"
            } catch {
                message = Self.describe(error, action: "リンクを作れませんでした")
            }
        }
    }

    private func revoke(_ share: MinutesCloudShare) {
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await model.client.revokeShare(recordingID: recordingID, shareID: share.id)
                shares.removeAll { $0.id == share.id }
                if copiedID == share.id { copiedID = nil }
            } catch {
                message = Self.describe(error, action: "取り消せませんでした")
            }
        }
    }

    /// 誤りの文言。有料でない（402）はリンクの共有の言葉にする（共通の文言は文字起こしと要約の話）
    static func describe(_ error: Error, action: String) -> String {
        if let cloud = error as? MinutesCloudError, cloud.status == 402 {
            return "リンクでの共有は、有料のプランで使えます"
        }
        return "\(action)（\(error.localizedDescription)）"
    }
}
