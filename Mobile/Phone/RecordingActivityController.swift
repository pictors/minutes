// Activity は Sendable と書かれていない（ActivityKit が並行の決まりの前の作り）。MainActor の上だけで扱う
@preconcurrency import ActivityKit
import Foundation
import Observation

/// 録音中の Live Activity を出し入れする（SPEC §5.7）。アプリを離れても、ロック画面とダイナミックアイランドで、録れていることと経過時間が分かる。
/// - 録音が始まったら出す（録音は必ず前面で始まるので、前面でしか出せない決まりに当たらない）。中断・再開で中身を替え、止めたら消す。
/// - 録音の状態は画面（SwiftUI）ではなく、ここで直接見張る（電話で中断したときなど、アプリが裏にいても替えるため）。
/// - 起動したときに残っていたもの（録音中にアプリが落ちた・消された）は消す。
/// - 利用者が Live Activity を切っている（設定 > Minutes）ときは、何もしない。
/// 確認済み（Xcode 27.2 の iOS 27.2 SDK の ActivityKit の swiftinterface）: `Activity.request(attributes:content:pushType:)`・
/// `Activity.update(_:)`・`Activity.end(_:dismissalPolicy:)`・`Activity.activities`・`ActivityContent(state:staleDate:)`・
/// `ActivityAuthorizationInfo().areActivitiesEnabled`。
@MainActor
final class RecordingActivityController {
    private let recorder: MeetingRecorder
    private var activity: Activity<RecordingActivityAttributes>?
    private var shown: RecordingActivityAttributes.ContentState?
    /// 出す・替える・消すを、頼んだ順に 1 つずつ行う
    private var queue: Task<Void, Never>?

    init(recorder: MeetingRecorder) {
        self.recorder = recorder
    }

    func start() {
        let stale = Activity<RecordingActivityAttributes>.activities
        enqueue {
            for activity in stale { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        observe()
        sync()
    }

    private func observe() {
        withObservationTracking {
            _ = recorder.phase
            _ = recorder.runStartedAt
            _ = recorder.closedSeconds
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func sync() {
        guard recorder.isActive else {
            end()
            return
        }
        let recording = recorder.phase == .recording
        let state = RecordingActivityAttributes.ContentState(
            isRecording: recording,
            timerStart: recording ? recorder.runStartedAt.map { $0.addingTimeInterval(-recorder.closedSeconds) } : nil,
            elapsed: recorder.closedSeconds)
        guard state != shown else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            shown = state
            enqueue { await activity.update(content) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            // 出せなかったとき（裏にいる・上限など）は、次に状態が変わったときにもう一度試す。録音は止めない
            guard let created = try? Activity.request(attributes: RecordingActivityAttributes(), content: content, pushType: nil) else { return }
            activity = created
            shown = state
        }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        shown = nil
        enqueue { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Activity は Sendable でないので、仕事は MainActor の上で順に走らせる（Activity をほかの並行の領域へ渡さない）
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            await work()
        }
    }
}
