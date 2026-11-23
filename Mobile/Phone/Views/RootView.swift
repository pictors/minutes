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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.becameActive() }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await model.watchProgress()
        }
    }
}
