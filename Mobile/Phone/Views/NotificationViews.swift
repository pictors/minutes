import SwiftUI
import UIKit
import UserNotifications

/// 一覧の上の誘い: 議事録を待つ会議ができたら、通知を受け取るかを聞く。OS の確認は「通知を受け取る」を押してから出す
/// （いきなり出すと、断られたら設定のアプリからしか戻せない）。「あとで」で閉じたら、もう出さない（アカウントの画面から受け取れる）。
struct NotificationPromptCard: View {
    let push: PushNotifications

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.periwinkle)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text("議事録ができたら、通知で知らせます")
                        .font(.body.weight(.semibold))
                    Text("Apple Watch で録った会議も、この iPhone に知らせます。処理できなかったときも知らせます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button("通知を受け取る") {
                    Task { await push.requestAuthorization() }
                }
                .buttonStyle(FilledPillButtonStyle(height: 42))
                .accessibilityIdentifier("notifications.prompt.allow")
                Button("あとで") { push.dismissPrompt() }
                    .buttonStyle(PillButtonStyle(height: 42))
                    .accessibilityIdentifier("notifications.prompt.later")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// 誘いを出すか: 許可をまだ選んでいない・「あとで」で閉じていない・議事録を待つ（録り終えた）会議が一覧にある。
    static func shouldShow(push: PushNotifications, model: PhoneModel) -> Bool {
        push.authorizationLoaded && push.authorization == .notDetermined && !push.promptDismissed
            && model.meetings.contains { $0.id != model.recorder.clientId }
    }
}

/// アカウントの画面の「通知」: いまの許可と、変える道（まだ選んでいなければ受け取る、選んだあとは設定のアプリ）。
struct NotificationSettingsCard: View {
    let push: PushNotifications
    @Environment(\.openURL) private var openURL

    var body: some View {
        SectionCard("通知", systemImage: "bell.fill", tint: Palette.amber) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(status)
                        .font(.body.weight(.medium))
                    Spacer(minLength: 8)
                    if push.authorization == .notDetermined {
                        Button("受け取る") {
                            Task { await push.requestAuthorization() }
                        }
                        .buttonStyle(PillButtonStyle(height: 36))
                        .accessibilityIdentifier("account.notifications.allow")
                    } else {
                        Button("設定を開く") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(PillButtonStyle(height: 36))
                        .accessibilityIdentifier("account.notifications.settings")
                    }
                }
                Text("議事録ができたとき・処理できなかったときに知らせます（Apple Watch で録った会議も）。通知には会議の名前や中身を入れず、録った日時・機器・長さだけを書きます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await push.refreshAuthorization() }
    }

    private var status: String {
        switch push.authorization {
        case .notDetermined: "まだ選んでいません"
        case .denied: "切っています"
        default: "受け取ります"
        }
    }
}

/// 押した通知の会議を開く（MeetingListView の NavigationStack に付ける）。一覧を読み直してから、その会議の画面へ進む。
/// 開いているシート（アカウント・共有など）は先に閉じる。録音中は録音の画面の下で開く（録音の画面は閉じない）。
/// 会議が一覧にない（消された・別のアカウントの通知）ときは、一覧のまま。
struct OpensNotifiedMeeting: ViewModifier {
    @Environment(PhoneModel.self) private var model
    @Binding var path: [String]

    func body(content: Content) -> some View {
        content
            .onChange(of: PushNotifications.shared.openRequest, initial: true) { _, clientId in
                guard let clientId else { return }
                PushNotifications.shared.openRequest = nil
                Task { await open(clientId) }
            }
    }

    private func open(_ clientId: String) async {
        await model.refresh()
        guard model.meetings.contains(where: { $0.id == clientId }) else { return }
        if model.recorder.isActive {
            path = [clientId]
            return
        }
        PresentedSheets.closeAll {
            path = [clientId]
        }
    }
}

/// 開いているシートを UIKit で閉じてから続ける（QuickRecordHandler と、押した通知の会議を開くとき）。
/// シートが開いたままだと、その下の画面の移り変わり（録音の画面・会議の画面）が見えないまま進む。
/// UIKit で閉じても、シートを出した側の SwiftUI の状態は戻る（閉じたあと「録音」のボタンとアカウントのシートが、また開けることを確かめた）。
enum PresentedSheets {
    @MainActor
    static func closeAll(then action: @escaping @MainActor () -> Void) {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        guard let root, root.presentedViewController != nil else {
            action()
            return
        }
        root.dismiss(animated: true) { action() }
    }
}
