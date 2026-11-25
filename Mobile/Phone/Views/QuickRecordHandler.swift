import SwiftUI
import UIKit

/// ウィジェット・コントロール・Siri・ショートカットの「録音を始める」（`QuickRecord`。SPEC §5.7）を、アプリが前面になってから受け取る（RootView に付ける）。
/// Watch の `WatchRootView.takeQuickRecord` と同じ流れ。iPhone では「新しい会議」のシートを通らず、題名なしですぐ始める
/// （一覧には「無題の会議」で出て、あとで題名を直せる。参加者への念押しは録音の画面に出す）。
/// - ログインしていない: 何もしない（アプリが開いてログインの画面が出る）。求めは捨てる（あとでログインしても始めない）。
/// - 録音中・始めているところ: 何もしない（録音の画面が見える。2 本目は始めない）。
/// - 録音の告知にまだ同意していない: 告知を出し、「わかりました」で閉じたらすぐに始める。「やめる」なら始めない。
/// - 始められなければ（マイクの許可がないなど）、アラートで知らせる。
/// - シート（アカウント・新しい会議・共有など）が開いていたら、先に閉じる（`PresentedSheets.closeAll`）。
struct QuickRecordHandler: ViewModifier {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showingNotice = false
    /// 告知で「わかりました」を押した（閉じ終えたら始める）
    @State private var noticeAccepted = false
    /// 始めているところ（マイクの許可を待つあいだに次の求めが来ても、2 本目を始めない）
    @State private var starting = false
    @State private var failure: StartFailure?

    func body(content: Content) -> some View {
        content
            .onChange(of: QuickRecord.shared.isPending, initial: true) { take() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { take() }
            }
            // ウィジェットがボタンの Intent でなく widgetURL でアプリを開いたとき（ロック画面の円）
            .onOpenURL { url in
                if QuickRecord.isRecordURL(url) { QuickRecord.shared.request() }
            }
            .sheet(isPresented: $showingNotice, onDismiss: noticeDismissed) {
                RecordingNoticeView {
                    model.noticeAccepted = true
                    noticeAccepted = true
                    showingNotice = false
                }
            }
            .alert("録音を始められませんでした", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }), presenting: failure) { failure in
                if failure.offersSettings {
                    Button("設定を開く") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure.message)
            }
    }

    private func take() {
        guard scenePhase == .active, QuickRecord.shared.take() else { return }
        guard model.isSignedIn else { return }
        guard !model.recorder.isActive, !starting, !showingNotice else { return }
        // 開いているシート（アカウント・新しい会議・共有など）を閉じてから続ける。シートが開いたままだと、録音の画面
        // （MeetingListView の fullScreenCover）も告知もその上に出ず、録音が見えないまま進む（シミュレータで確かめた）
        PresentedSheets.closeAll {
            if model.noticeAccepted {
                start()
            } else {
                showingNotice = true
            }
        }
    }

    /// 告知のシートが閉じ終えた（閉じてから始めると、録音の画面がシートと重ならずに出る）。
    private func noticeDismissed() {
        guard noticeAccepted else { return }
        noticeAccepted = false
        start()
    }

    private func start() {
        guard !starting, !model.recorder.isActive else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                // 録音の画面（MeetingListView の fullScreenCover）は recorder.isActive で出る
                try await model.recorder.start(title: nil)
            } catch RecorderError.alreadyRecording {
                // ほかの入口ですでに始まっていた
            } catch {
                failure = StartFailure(error)
            }
        }
    }
}

private struct StartFailure {
    let message: String
    /// マイクの許可がない（設定アプリへの道を出す）
    let offersSettings: Bool

    init(_ error: Error) {
        message = error.localizedDescription
        if case RecorderError.microphoneDenied = error {
            offersSettings = true
        } else {
            offersSettings = false
        }
    }
}

extension View {
    /// ウィジェット・コントロール・Siri・ショートカットからの「録音を始める」を受け取る。
    func handlesQuickRecord() -> some View {
        modifier(QuickRecordHandler())
    }
}
