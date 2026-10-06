import Foundation

/// SPEC §6.3 の状態機械。純粋な遷移表（テスト対象）。
public enum SessionState: String, Sendable, Codable, CaseIterable {
    case idle, armed, recording, finalizing, done, failed
}

public enum SessionEvent: Sendable, Equatable {
    /// (c) カレンダー開始 5 分前 かつ (a) 対象プロセス起動
    case armConditionMet
    case disarm
    /// (b) system track の音声レベルが閾値超え
    case audioDetected
    case manualStart
    case silenceTimeout
    case targetProcessExited
    case calendarEndPassed
    case manualStop
    /// finalizing 中 1 分以内に音声が再開
    case audioResumed
    case captureFailed(String)
    /// 録音ファイルを閉じ、後処理依頼を永続化した。後処理を待たず次の録音へ。
    case recordingFinished
    case pipelineSucceeded
    case pipelineFailed(String)
    case retryPipeline
    case reset
}

public struct SessionTransitionError: Error, LocalizedError, Equatable {
    public var state: SessionState
    public var event: SessionEvent

    public var errorDescription: String? { "状態 \(state.rawValue) でイベント \(event) は無効です" }
}

public struct SessionStateMachine: Sendable, Equatable {
    public private(set) var state: SessionState

    public init(state: SessionState = .idle) {
        self.state = state
    }

    /// 遷移先。無効なら nil。
    public static func next(from state: SessionState, on event: SessionEvent) -> SessionState? {
        switch (state, event) {
        case (_, .reset):
            return .idle
        case (.idle, .captureFailed), (.armed, .captureFailed), (.recording, .captureFailed), (.finalizing, .captureFailed):
            return .failed
        case (.idle, .armConditionMet):
            return .armed
        case (.idle, .manualStart):
            return .recording
        case (.armed, .audioDetected), (.armed, .manualStart):
            return .recording
        case (.armed, .disarm), (.armed, .targetProcessExited):
            return .idle
        case (.recording, .silenceTimeout), (.recording, .targetProcessExited), (.recording, .manualStop), (.recording, .calendarEndPassed):
            return .finalizing
        case (.finalizing, .audioResumed):
            return .recording
        case (.finalizing, .manualStop):
            return .finalizing
        case (.finalizing, .recordingFinished):
            return .idle
        case (.finalizing, .pipelineSucceeded):
            return .done
        case (.finalizing, .pipelineFailed):
            return .failed
        case (.failed, .retryPipeline):
            return .finalizing
        default:
            return nil
        }
    }

    @discardableResult
    public mutating func handle(_ event: SessionEvent) throws -> SessionState {
        guard let next = SessionStateMachine.next(from: state, on: event) else {
            throw SessionTransitionError(state: state, event: event)
        }
        state = next
        return next
    }
}
