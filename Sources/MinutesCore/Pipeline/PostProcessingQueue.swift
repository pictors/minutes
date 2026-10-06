import Foundation
import Synchronization

/// 録音と独立して存続する、永続・直列の後処理ワーカー。
public actor PostProcessingQueue {
    public enum Event: Sendable {
        /// 完了。要約・書き出しなど任意ステップの失敗は warnings に入る（会議は done）。
        case completed(meetingId: String, warnings: [PipelineStep: String])
        case failed(meetingId: String, message: String)
        case unavailable(String)
    }

    private let store: Store
    private let pipeline: Mutex<PostProcessPipeline>
    private let onEvent: (@Sendable (Event) -> Void)?
    private var worker: Task<Void, Never>?

    public init(store: Store, pipeline: PostProcessPipeline, onEvent: (@Sendable (Event) -> Void)? = nil) {
        self.store = store
        self.pipeline = Mutex(pipeline)
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

    private func drain() async {
        defer { worker = nil }
        do {
            while !Task.isCancelled {
                let pending = try store.postProcessingJobs().filter { $0.jobStatus != .failed }
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
                            let currentPipeline = pipeline.withLock { $0 }
                            let outcome: PipelineOutcome
                            do {
                                outcome = try await currentPipeline.run(meetingId: job.meetingId, lease: lease)
                            } catch {
                                try store.finishPostProcessing(meetingId: job.meetingId, lease: lease, error: error.localizedDescription)
                                onEvent?(.failed(meetingId: job.meetingId, message: error.localizedDescription))
                                continue
                            }
                            // 完了後の DB 書き込み失敗では、処理の成功を failed に戻さない。
                            try store.finishPostProcessing(meetingId: job.meetingId, lease: lease)
                            onEvent?(.completed(meetingId: job.meetingId, warnings: outcome.warnings))
                        } catch StoreError.meetingBusy { continue }
                    }
                } catch StoreError.meetingBusy { /* 別ワーカーの終了を待つ */ }
                if try store.postProcessingJobs().contains(where: { $0.jobStatus != .failed }) {
                    try await Task.sleep(for: .seconds(1))
                }
            }
        } catch is CancellationError {
            // 未完了の依頼は DB に残り、次の起動時に再開する。
        } catch { onEvent?(.unavailable(error.localizedDescription)) }
    }
}
