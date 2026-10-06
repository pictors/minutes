import Foundation
import Synchronization

/// シグナル・時間切れ・capture failure を一つの停止理由に集約する。wait 前の失敗も保持する。
public final class RecordingStopRequest: Sendable {
    public enum Reason: Sendable, Equatable {
        case signal, timeout, cancelled
        case failure(CaptureFailure)
    }
    private struct State {
        var reason: Reason?
        var waiters: [CheckedContinuation<Reason, Never>] = []
    }
    private let state = Mutex(State())

    public init() {}

    public func request(_ reason: Reason) {
        let waiters = state.withLock { state -> [CheckedContinuation<Reason, Never>] in
            guard state.reason == nil else { return [] }
            state.reason = reason
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: reason) }
    }

    public func wait() async -> Reason {
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter in
                let reason = state.withLock { state -> Reason? in
                    if let reason = state.reason { return reason }
                    state.waiters.append(waiter)
                    return nil
                }
                if let reason { waiter.resume(returning: reason) }
            }
        } onCancel: { self.request(.cancelled) }
    }
}

/// CLI の共通ライフサイクル。開始途中・ログ準備・録音の失敗でも一度だけファイルを閉じる。
public final class RecordingRun: Sendable {
    public let stopRequest = RecordingStopRequest()
    private let recording: any MeetingRecording
    private let finished = Mutex(false)

    public init(recording: any MeetingRecording) { self.recording = recording }

    public func start() async throws {
        recording.onFailure = { [stopRequest] failure in stopRequest.request(.failure(failure)) }
        do {
            try await recording.start()
            try Task.checkCancellation()
        } catch {
            try? close()
            throw error
        }
    }

    public func close() throws {
        let shouldClose = finished.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        guard shouldClose else { return }
        defer { recording.onFailure = nil }
        try recording.finishRecording()
    }

    public func finish(after reason: RecordingStopRequest.Reason) throws {
        let closed = Result { try close() }
        switch reason {
        case let .failure(failure): throw failure
        case .cancelled: throw CancellationError()
        case .signal, .timeout: try closed.get()
        }
    }
}
