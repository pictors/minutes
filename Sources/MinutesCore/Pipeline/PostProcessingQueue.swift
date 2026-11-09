import Foundation
import Synchronization

/// 録音と独立して存続する、永続・直列の後処理ワーカー。
/// スリープ・回線・混雑で止めた依頼（`DeferredFailure`）は失敗にせず、条件がそろったら続きから再開する（SPEC §8.2）。
public actor PostProcessingQueue {
    public enum Event: Sendable {
        /// 完了。要約・書き出しなど任意ステップの失敗は warnings に入る（会議は done）。
        case completed(meetingId: String, warnings: [PipelineStep: String])
        case failed(meetingId: String, message: String)
        /// スリープ・回線・混雑で止めた。会議は処理中のまま、条件がそろったら再開する。
        case deferred(meetingId: String, message: String)
        case unavailable(String)
    }

    /// やり直しまでの待ち。起きている時間（`SuspendingClock`）で数える（スリープ中は進まない）。
    public struct RetryTiming: Sendable {
        /// スリープで止めたあと、Mac が起きた知らせ（`systemDidWake`）がなくても再開するまでの時間。
        public var afterSleep: Duration
        /// Mac が起きた・回線がつながった知らせから再開までの待ち（回線が使えるようになるのを待つ）。
        /// 依頼の実行中に起きた知らせが届いていたら、止めたあとこの時間で再開する（蓋を開けると、知らせは送信の中断より先に届く）。
        public var afterWake: Duration
        /// 回線がつながっているのに失敗したときの待ち（回数ごと。最後の値を繰り返す）。
        public var backoff: [Duration]
        /// 回線が切れているときに、つながった知らせがなくても試し直すまでの時間。
        public var offlineRecheck: Duration

        public init(afterSleep: Duration, afterWake: Duration, backoff: [Duration], offlineRecheck: Duration) {
            self.afterSleep = afterSleep
            self.afterWake = afterWake
            self.backoff = backoff
            self.offlineRecheck = offlineRecheck
        }

        public static let standard = RetryTiming(afterSleep: .seconds(300), afterWake: .seconds(10),
                                                 backoff: [.seconds(15), .seconds(60), .seconds(300)], offlineRecheck: .seconds(600))
    }

    /// 回線がつながっているのにクラウドの文字起こしが回線・混雑で失敗した回数がこれに達したら、待たずにローカルに切り替える。
    static let transientFailureLimit = 3
    /// スリープで止める回数の上限（スリープの判定を誤っても、送信を繰り返し続けない）。
    static let sleepDeferralLimit = 20

    private struct Waiting {
        var reason: DeferReason
        var notBefore: SuspendingClock.Instant
        /// 止めたときの依頼の時刻。依頼し直されたら（時刻が変わったら）待たずに始める。
        var enqueuedAt: Date
    }

    private let store: Store
    private let pipeline: Mutex<PostProcessPipeline>
    private let onEvent: (@Sendable (Event) -> Void)?
    private let isNetworkAvailable: (@Sendable () -> Bool)?
    private let timing: RetryTiming
    private var worker: Task<Void, Never>?
    private var retryTimer: Task<Void, Never>?
    private var waiting: [String: Waiting] = [:]
    private var transientFailures: [String: Int] = [:]
    private var sleepDeferrals: [String: Int] = [:]
    /// 最後に Mac が起きた知らせを受けた時刻（起きている時間で数える）。
    private var lastWake: SuspendingClock.Instant?

    /// - Parameter isNetworkAvailable: 回線がつながっているか（アプリは `NetworkPathWatcher`）。nil ならつながっているとみなす。
    ///   `onEvent` より後ろに置く（後ろに書くクロージャを `onEvent` に渡す既存の呼び方を保つ）。
    public init(store: Store, pipeline: PostProcessPipeline, onEvent: (@Sendable (Event) -> Void)? = nil,
                isNetworkAvailable: (@Sendable () -> Bool)? = nil, timing: RetryTiming = .standard) {
        self.store = store
        self.pipeline = Mutex(pipeline)
        self.isNetworkAvailable = isNetworkAvailable
        self.timing = timing
        self.onEvent = onEvent
    }

    /// 実行中の仕事は元の設定で完了し、次に取り出す仕事から新しい設定を使う。
    public nonisolated func updatePipeline(_ pipeline: PostProcessPipeline) {
        self.pipeline.withLock { $0 = pipeline }
    }

    public func start() {
        guard worker == nil else { return }
        worker = Task { await drain() }
    }

    public func waitUntilIdle() async { await worker?.value }

    /// Mac が起きた（アプリがスリープからの復帰・画面の点灯の知らせで呼ぶ）。スリープで止めた依頼を少し待って再開する。
    /// 送信中の依頼はまだ止まっていないことが多い（見張りが気づくのは少しあと）ので、知らせの時刻を覚えておく。
    public func systemDidWake() {
        lastWake = .now
        resumeWaiting(.sleep)
    }

    /// 回線がつながった（アプリが `NetworkPathWatcher` の知らせで呼ぶ）。回線を待っていた依頼を少し待って再開する。
    public func networkBecameAvailable() {
        resumeWaiting(.network)
    }

    /// 待っている依頼を、待たずにすぐ試す（会議の画面の「今すぐやり直す」。回線の知らせが誤っているときなど）。
    public func retryNow(meetingId: String) {
        guard waiting[meetingId] != nil else { return }
        waiting[meetingId]?.notBefore = .now
        start()
    }

    /// 待っている依頼の理由（テストと画面の確認用）。
    public func waitingReason(meetingId: String) -> DeferReason? { waiting[meetingId]?.reason }

    private func resumeWaiting(_ reason: DeferReason) {
        let soon = SuspendingClock.now.advanced(by: timing.afterWake)
        for (id, entry) in waiting where entry.reason == reason && entry.notBefore > soon {
            waiting[id]?.notBefore = soon
        }
        scheduleRetry()
    }

    private func drain() async {
        defer {
            worker = nil
            scheduleRetry()
        }
        do {
            while !Task.isCancelled {
                let jobs = try store.postProcessingJobs().filter { $0.jobStatus != .failed }
                // 消えた・失敗した依頼の待ちは捨てる（残すと、過ぎた待ちの時刻でワーカーを起こし続ける）
                let ids = Set(jobs.map(\.meetingId))
                for id in Array(waiting.keys) where !ids.contains(id) { forget(id) }
                let pending = jobs.filter { isReady($0) }
                guard !pending.isEmpty else { return }
                // 同じ DB を開いた別ワーカーとも直列化する。録音の会議ロックは独立。
                do {
                    let queueLease = try store.acquireMeetingLease("post-processing-worker")
                    defer { withExtendedLifetime(queueLease) {} }
                    for job in pending {
                        try Task.checkCancellation()
                        do {
                            let lease = try store.acquireMeetingLease(job.meetingId)
                            defer { withExtendedLifetime(lease) {} }
                            guard try store.beginPostProcessing(meetingId: job.meetingId, lease: lease) else { continue }
                            waiting[job.meetingId] = nil
                            let currentPipeline = pipeline.withLock { $0 }
                            let runStarted = SuspendingClock.now
                            let outcome: PipelineOutcome
                            do {
                                outcome = try await currentPipeline.run(meetingId: job.meetingId, lease: lease, policy: policy(for: job.meetingId))
                            } catch let failure as DeferredFailure {
                                // 失敗にしない。依頼を待ちに戻し、会議は処理中のまま
                                try store.deferPostProcessing(meetingId: job.meetingId, lease: lease, message: failure.reason.waitingMessage)
                                wait(after: failure, job: job, runStarted: runStarted)
                                onEvent?(.deferred(meetingId: job.meetingId, message: failure.localizedDescription))
                                continue
                            } catch {
                                forget(job.meetingId)
                                try store.finishPostProcessing(meetingId: job.meetingId, lease: lease, error: error.localizedDescription)
                                onEvent?(.failed(meetingId: job.meetingId, message: error.localizedDescription))
                                continue
                            }
                            forget(job.meetingId)
                            // 完了後の DB 書き込み失敗では、処理の成功を failed に戻さない。
                            try store.finishPostProcessing(meetingId: job.meetingId, lease: lease)
                            onEvent?(.completed(meetingId: job.meetingId, warnings: outcome.warnings))
                        } catch StoreError.meetingBusy { continue }
                    }
                } catch StoreError.meetingBusy { /* 別ワーカーの終了を待つ */ }
                if try store.postProcessingJobs().contains(where: { $0.jobStatus != .failed && isReady($0) }) {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        } catch is CancellationError {
            // 未完了の依頼は DB に残り、次の起動時に再開する。
        } catch { onEvent?(.unavailable(error.localizedDescription)) }
    }

    /// 待っていない依頼か、待ちの時間を過ぎた依頼。依頼し直された依頼は待たない。
    private func isReady(_ job: PostProcessingJob) -> Bool {
        guard let entry = waiting[job.meetingId], entry.enqueuedAt == job.enqueuedAt else { return true }
        return SuspendingClock.now >= entry.notBefore
    }

    /// 同じ会議で何度止めたかに応じて、次に待つかどうかを決める（上限を超えたら、これまでどおり失敗・ローカルに切り替える）。
    private func policy(for meetingId: String) -> RetryPolicy {
        RetryPolicy(deferOnSleep: sleepDeferrals[meetingId, default: 0] < Self.sleepDeferralLimit,
                    deferTransientCloudFailures: transientFailures[meetingId, default: 0] < Self.transientFailureLimit)
    }

    private func wait(after failure: DeferredFailure, job: PostProcessingJob, runStarted: SuspendingClock.Instant) {
        let delay: Duration
        switch failure.reason {
        case .sleep:
            sleepDeferrals[job.meetingId, default: 0] += 1
            // 実行中に起きた知らせが届いていれば、もう起きている（蓋を開けたとき）。届いていなければ、起きている時間で待つ
            let wokeDuringRun = lastWake.map { $0 > runStarted } ?? false
            delay = wokeDuringRun ? timing.afterWake : timing.afterSleep
        case .network where !(isNetworkAvailable?() ?? true):
            // 回線が切れているあいだは数えない（つながった知らせで再開する）
            delay = timing.offlineRecheck
        case .network, .server:
            transientFailures[job.meetingId, default: 0] += 1
            let count = transientFailures[job.meetingId, default: 1]
            delay = timing.backoff.isEmpty ? .zero : timing.backoff[min(count, timing.backoff.count) - 1]
        }
        waiting[job.meetingId] = Waiting(reason: failure.reason, notBefore: SuspendingClock.now.advanced(by: delay), enqueuedAt: job.enqueuedAt)
    }

    private func forget(_ meetingId: String) {
        waiting[meetingId] = nil
        transientFailures[meetingId] = nil
        sleepDeferrals[meetingId] = nil
    }

    /// いちばん早く待ちの終わる依頼に合わせて、ワーカーを起こす。
    private func scheduleRetry() {
        retryTimer?.cancel()
        retryTimer = nil
        guard let earliest = waiting.values.map(\.notBefore).min() else { return }
        retryTimer = Task { [weak self] in
            try? await SuspendingClock().sleep(until: earliest, tolerance: nil)
            guard !Task.isCancelled else { return }
            await self?.start()
        }
    }
}
