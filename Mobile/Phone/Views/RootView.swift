import SwiftUI

struct RootView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.isSignedIn {
                MeetingListView()
            } else {
                SignInView()
            }
        }
        .tint(Palette.periwinkle)
        .animation(Motion.layout, value: model.isSignedIn)
        // メールのコードでログインした直後に、1 度だけパスキーを勧める
        .sheet(isPresented: Bindable(model).passkeyOfferPending) {
            PasskeyOfferView()
        }
        // ウィジェット・コントロール・Siri・ショートカットの「録音を始める」（QuickRecord。SPEC §5.7）
        .handlesQuickRecord()
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.becameActive() }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await model.watchProgress()
        }
    }
}
