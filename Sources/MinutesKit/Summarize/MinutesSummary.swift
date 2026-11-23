import Foundation

/// Summarizer の構造化出力（SPEC §8.1）。evidence は segment id。
public struct MinutesSummary: Codable, Sendable, Equatable {
    public struct Decision: Codable, Sendable, Equatable {
        public var text: String
        public var evidence: [Int]

        public init(text: String, evidence: [Int]) {
            self.text = text
            self.evidence = evidence
        }
    }

    public enum ActionKind: String, Codable, Sendable, CaseIterable {
        /// 自分が「やる」と言ったもの → 自分のタスクとして扱う
        case ownCommitment = "own_commitment"
        /// 相手の宿題 → 追跡のみ
        case theirTask = "their_task"
        /// エージェントに任せられるもの → 提案として作成、実行は承認
        case delegable
    }

    public struct ActionItem: Codable, Sendable, Equatable {
        public var text: String
        /// "me" | 参加者名 | "agent"
        public var owner: String
        public var kind: ActionKind
        /// "2026-09-20" | nil
        public var due: String?
        public var evidence: [Int]
        /// UI のチェック状態（Summarizer の出力には含まれない）。
        public var done: Bool?
        /// 保存時に採番する安定 ID（再要約・外部連携での同一性）。Summarizer の出力には含まれない。
        public var id: String?
        /// 人が追加したアクション。再要約で消さない。
        public var manual: Bool?

        public init(text: String, owner: String, kind: ActionKind, due: String?, evidence: [Int], done: Bool? = nil, id: String? = nil, manual: Bool? = nil) {
            self.text = text
            self.owner = owner
            self.kind = kind
            self.due = due
            self.evidence = evidence
            self.done = done
            self.id = id
            self.manual = manual
        }

        /// 文言・担当・種別・期限が同じなら同じアクションとみなす（ID がない旧データ・生成直後の照合用）。
        public func matchesContent(of other: ActionItem) -> Bool {
            text == other.text && owner == other.owner && kind == other.kind && due == other.due
        }
    }

    public struct OpenQuestion: Codable, Sendable, Equatable {
        public var text: String
        public var evidence: [Int]

        public init(text: String, evidence: [Int]) {
            self.text = text
            self.evidence = evidence
        }
    }

    public var summaryMd: String
    public var decisions: [Decision]
    public var actionItems: [ActionItem]
    public var openQuestions: [OpenQuestion]
    public var keytermsLearned: [String]

    public init(summaryMd: String, decisions: [Decision], actionItems: [ActionItem], openQuestions: [OpenQuestion], keytermsLearned: [String]) {
        self.summaryMd = summaryMd
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
        self.keytermsLearned = keytermsLearned
    }

    public static let empty = MinutesSummary(summaryMd: "", decisions: [], actionItems: [], openQuestions: [], keytermsLearned: [])

    /// evidence の segment id を写像で置き換える（ローカル id → DB id）。
    public func remappingEvidence(_ map: [Int: Int]) -> MinutesSummary {
        func remap(_ ids: [Int]) -> [Int] { ids.compactMap { map[$0] } }
        return MinutesSummary(
            summaryMd: summaryMd,
            decisions: decisions.map { Decision(text: $0.text, evidence: remap($0.evidence)) },
            actionItems: actionItems.map { ActionItem(text: $0.text, owner: $0.owner, kind: $0.kind, due: $0.due, evidence: remap($0.evidence), done: $0.done, id: $0.id, manual: $0.manual) },
            openQuestions: openQuestions.map { OpenQuestion(text: $0.text, evidence: remap($0.evidence)) },
            keytermsLearned: keytermsLearned
        )
    }
}

/// 要約の入力。
public struct SummaryInput: Codable, Sendable {
    public var meetingTitle: String
    public var startedAt: Date?
    public var attendees: [Attendee]
    /// 話者名解決済みのセグメント（id は evidence の参照先）。
    public var segments: [TranscriptDocument.Segment]
    /// 話者ラベル → 表示名。
    public var speakerNames: [String: String]
    /// 同シリーズ前回の要約（Phase 3）。
    public var previousSummaryMd: String?
    /// 会議で話された言語。nil は日本語。
    public var meetingLanguage: MeetingLanguage?
    /// 要約を書く言語。nil は日本語。
    public var outputLanguage: MeetingLanguage?

    public init(meetingTitle: String, startedAt: Date?, attendees: [Attendee], segments: [TranscriptDocument.Segment], speakerNames: [String: String] = [:], previousSummaryMd: String? = nil, meetingLanguage: MeetingLanguage? = nil, outputLanguage: MeetingLanguage? = nil) {
        self.meetingTitle = meetingTitle
        self.startedAt = startedAt
        self.attendees = attendees
        self.segments = segments
        self.speakerNames = speakerNames
        self.previousSummaryMd = previousSummaryMd
        self.meetingLanguage = meetingLanguage
        self.outputLanguage = outputLanguage
    }

    public var durationSeconds: Double { segments.map(\.tEnd).max() ?? 0 }

    /// プロンプトに入れる話者付き全文（segment id 付き）。
    public func transcriptText() -> String {
        segments.map { segment in
            let speaker = segment.speaker.map { speakerNames[$0] ?? $0 } ?? "?"
            return "[seg \(segment.id)][\(TimeFormatting.hms(segment.tStart))] \(speaker): \(segment.text)"
        }.joined(separator: "\n")
    }
}

public protocol Summarizing: Sendable {
    /// notes.model に記録する文字列（'claude-sonnet-5 / prompt v1' など）。
    var modelDescription: String { get }
    var cacheIdentity: String { get }
    func summarize(_ input: SummaryInput) async throws -> MinutesSummary
}

public extension Summarizing {
    var cacheIdentity: String { modelDescription }
}

public enum SummarizerError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case httpError(status: Int, body: String, requestID: String?)
    case invalidResponse(String)
    case refused(String)
    case truncated

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Anthropic の API キーがありません（Keychain または ANTHROPIC_API_KEY）"
        case let .httpError(status, body, requestID):
            return "Claude API が HTTP \(status) を返しました\(requestID.map { " request-id=\($0)" } ?? ""): \(Log.preview(body, limit: 300))"
        case let .invalidResponse(detail): return "Claude API のレスポンスを解釈できません: \(detail)"
        case let .refused(detail): return "Claude が要約を拒否しました: \(detail)"
        case .truncated: return "要約が max_tokens で途中終了しました"
        }
    }
}
