import Foundation

/// Minutes の MCP サーバーの中身（読み取りだけ）。会議のあとに Claude などから会議を読み、議事録・チケットに起こすため。
///
/// - `privacy_mode = local_only` の会議は外部に送らない約束（SPEC §14）なので、一覧・検索・読み取りのどれにも出さない。
/// - 背景の声として除外した話者の発話は、書き出しと同じく出さない。
/// - 本文はモデルが読みやすい Markdown で返す。発言は `#<segment id>` を付け、要約の根拠（evidence）と突き合わせられるようにする。
public struct MinutesMCPHandler: MCPHandler {
    public let store: Store
    public let serverVersion: String
    /// 書き出しフォルダ（meeting.md の場所を案内する）。nil なら案内しない。
    public let exportDirectory: URL?
    let now: @Sendable () -> Date
    let timeZone: TimeZone

    public init(store: Store, serverVersion: String, exportDirectory: URL?, now: @escaping @Sendable () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.store = store
        self.serverVersion = serverVersion
        self.exportDirectory = exportDirectory
        self.now = now
        self.timeZone = timeZone
    }

    public var serverName: String { "minutes" }
    public var serverTitle: String { "Minutes" }

    public var instructions: String {
        """
        Minutes は Mac で会議を録音・文字起こし・要約するアプリです。このサーバーで、保存された会議を読めます（読み取りだけ）。
        - 「今の会議」「さっきの会議」は、meeting_id を省いた get_meeting（直前の会議）で読めます。
        - 会議を探すときは list_meetings（日付・タグ）か search_meetings（本文・要約・タイトル・参加者の検索）。
        - 要約の決定事項・アクションには根拠の発言 ID（#123 の形）が付いています。発言の前後は get_transcript で読めます。
        - 会議は minutes://meeting/<会議 ID>、根拠の発言は minutes://meeting/<会議 ID>?seg=<発言 ID> で Minutes から開けます（利用者の Mac でだけ開くリンク）。チケットに根拠として添えられます。
        - アクションの「担当: 自分」は Minutes の利用者本人です。種別は own_commitment（自分の約束）、their_task（相手の宿題）、delegable（任せられる）。
        - 会議の状態が「後処理中」なら、文字起こしと要約がまだできていません。利用者にそう伝え、少し待ってから読み直してください。
        - チケット・タスク・ドキュメントを作るなど、ほかのサービスに書き込む前には、内容を利用者に見せて確認を取ってください。
        - ローカル専用（クラウドに送らない設定）の会議は、このサーバーからは読めません。
        """
    }

    // MARK: - Tools

    public var tools: [MCPTool] {
        let meetingId: JSONValue = ["type": "string", "description": "会議の ID（list_meetings・search_meetings で分かる）。省くと直前の会議"]
        return [
            MCPTool(
                name: "list_meetings",
                title: "会議の一覧",
                description: "保存された会議を新しい順に返す。日時・状態・参加者・タグ・要約の 1 行目が分かる。期間やタグで絞れる。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "since": ["type": "string", "description": "この日以降に始まった会議（YYYY-MM-DD か ISO 8601）"],
                        "until": ["type": "string", "description": "この日までに始まった会議（YYYY-MM-DD ならその日を含む）"],
                        "tag": ["type": "string", "description": "このタグが付いた会議"],
                        "limit": ["type": "integer", "description": "返す件数（既定 20、最大 100）", "minimum": 1, "maximum": 100],
                    ],
                    "additionalProperties": false,
                ]
            ),
            MCPTool(
                name: "get_meeting",
                title: "会議の議事録",
                description: "会議の要約・決定事項・アクション（担当・種別・期限・根拠の発言 ID）・未決の論点・利用者のメモ・参加者を返す。meeting_id を省くと直前の会議。include_transcript で全文も付ける。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "meeting_id": meetingId,
                        "include_transcript": ["type": "boolean", "description": "全文（話者・時刻つき）も付ける。長い会議では get_transcript で分けて読む（既定 false）"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            MCPTool(
                name: "get_transcript",
                title: "会議の全文",
                description: "会議の全文を、時刻・発言 ID・話者つきで返す。長い会議は start と limit で分けて読む。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "meeting_id": meetingId,
                        "start": ["type": "integer", "description": "何件目の発言から返すか（0 始まり、既定 0）", "minimum": 0],
                        "limit": ["type": "integer", "description": "返す発言の数（既定 400、最大 2000）", "minimum": 1, "maximum": 2000],
                    ],
                    "additionalProperties": false,
                ]
            ),
            MCPTool(
                name: "search_meetings",
                title: "会議の検索",
                description: "本文・要約・メモ・タイトル・参加者・タグを検索し、当たった会議と発言（前後の発言つき）を新しい順に返す。",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "探す言葉（日本語は 3 文字以上だと全文検索、2 文字以下は部分一致）"],
                        "limit": ["type": "integer", "description": "返す会議の数（既定 10、最大 50）", "minimum": 1, "maximum": 50],
                    ],
                    "required": ["query"],
                    "additionalProperties": false,
                ]
            ),
        ]
    }

    public func callTool(name: String, arguments: [String: JSONValue]) throws -> String {
        switch name {
        case "list_meetings": return try listMeetings(arguments)
        case "get_meeting": return try getMeeting(arguments)
        case "get_transcript": return try getTranscript(arguments)
        case "search_meetings": return try searchMeetings(arguments)
        default: throw MCPToolError("不明なツール: \(name)")
        }
    }

    // MARK: - Prompts

    public var prompts: [MCPPrompt] {
        [
            MCPPrompt(
                name: "minutes",
                title: "議事録にする",
                description: "Minutes の会議（省くと直前の会議）を読み、共有できる議事録にまとめる",
                arguments: [
                    .init(name: "meeting_id", description: "会議の ID。省くと直前の会議"),
                    .init(name: "destination", description: "議事録の置き場所（例: Notion の議事録データベース、Backlog の Wiki）。省くと案を見せて聞く"),
                ]
            ),
            MCPPrompt(
                name: "tasks",
                title: "タスクのチケットにする",
                description: "Minutes の会議（省くと直前の会議）のアクションを、Backlog・Notion などのチケットに起こす",
                arguments: [
                    .init(name: "meeting_id", description: "会議の ID。省くと直前の会議"),
                    .init(name: "destination", description: "チケットの作り先（例: Backlog のプロジェクト、Notion のタスクデータベース）。省くと聞く"),
                ]
            ),
        ]
    }

    public func prompt(name: String, arguments: [String: String]) throws -> String {
        let id = arguments["meeting_id"].flatMap { $0.isEmpty ? nil : $0 }
        let target = id.map { "Minutes の会議（meeting_id: \($0)）" } ?? "Minutes の直前の会議"
        let read = id.map { "get_meeting（meeting_id: \($0)）" } ?? "get_meeting（meeting_id は省く）"
        let destination = arguments["destination"].flatMap { $0.isEmpty ? nil : $0 }
        switch name {
        case "minutes":
            return """
            \(target)を議事録にしてください。

            1. \(read) で要約・決定事項・アクション・未決の論点・メモを読む。状態が「後処理中」なら、そう伝えて止める。
            2. 足りないところや根拠を確かめたいところは get_transcript で発言を読む（発言 ID は #123 の形）。
            3. 次の形で議事録を書く: 会議名・日時・参加者 / 要点 / 決定事項 / アクション（担当・期限）/ 未決の論点。
               推測で足さない。要約にない内容を書くときは、本文で確かめてから書く。
            4. \(destination.map { "書いた議事録を \($0) に置く。置く前に内容を見せて確認を取る。" } ?? "書いた議事録を見せ、どこに置くか（Notion・Backlog など、つながっているツール）を聞く。置く前に確認を取る。")
            """
        case "tasks":
            return """
            \(target)のアクションを、タスクのチケットに起こしてください。

            1. \(read) でアクションを読む。状態が「後処理中」なら、そう伝えて止める。
            2. アクションごとに、根拠の発言（#123 の形）を get_transcript で確かめ、背景・完了の条件を補う。
            3. チケットの案を一覧で見せる: 件名 / 担当 / 期限 / 説明（会議名・日時、根拠の発言の要旨、根拠へのリンク minutes://meeting/<会議 ID>?seg=<発言 ID>）。
               「担当: 自分」は利用者本人。their_task（相手の宿題）は、追いかけるためのチケットにするか聞く。完了済みのアクションは外す。
            4. \(destination.map { "利用者が OK したものだけを \($0) に作る。" } ?? "どこに作るか（Backlog のプロジェクト、Notion のデータベースなど、つながっているツール）を聞き、利用者が OK したものだけを作る。")
               作ったら、チケットの URL を一覧にして返す。
            """
        default:
            throw MCPToolError("不明なプロンプト: \(name)")
        }
    }

    // MARK: - list_meetings

    func listMeetings(_ arguments: [String: JSONValue]) throws -> String {
        let limit = min(max(arguments["limit"]?.intValue ?? 20, 1), 100)
        let since = try arguments["since"]?.stringValue.map { try parseDate($0, endOfDay: false, field: "since") }
        let until = try arguments["until"]?.stringValue.map { try parseDate($0, endOfDay: true, field: "until") }
        let tag = arguments["tag"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let filter: MeetingFilter = tag.map(MeetingFilter.tag) ?? since.map(MeetingFilter.since) ?? .all
        let meetings = try store.listMeetings(filter, limit: 5_000)
            .filter { $0.privacy == .cloudOk }
            .filter { meeting in since.map { meeting.startedAt >= $0 } ?? true }
            .filter { meeting in until.map { meeting.startedAt < $0 } ?? true }
            .prefix(limit)
        guard !meetings.isEmpty else { return "条件に合う会議はありません。" }
        var lines = ["会議 \(meetings.count) 件（新しい順）", ""]
        for meeting in meetings {
            lines.append("- \(meeting.title)")
            lines.append("  - ID: \(meeting.id)")
            lines.append("  - 日時: \(timeRange(meeting)) / 状態: \(statusText(meeting))")
            let attendees = meeting.attendees.map(\.name)
            if !attendees.isEmpty { lines.append("  - 参加者: \(attendees.joined(separator: ", "))") }
            if !meeting.tags.isEmpty { lines.append("  - タグ: \(meeting.tags.joined(separator: ", "))") }
            if let preview = try store.notes(meetingId: meeting.id)?.summaryMd.flatMap(firstLine) {
                lines.append("  - 要約: \(preview)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - get_meeting

    func getMeeting(_ arguments: [String: JSONValue]) throws -> String {
        let meeting = try resolveMeeting(arguments["meeting_id"]?.stringValue)
        let speakers = try store.speakers(meetingId: meeting.id)
        let display = try store.displaySegments(meetingId: meeting.id)
        let segments = BackgroundVoices.removingExcluded(display.segments, speakers: speakers)
        let notes = try store.notes(meetingId: meeting.id)
        let names = SpeakerNames(speakers: speakers)

        var lines = ["# \(meeting.title)", ""]
        lines.append("- ID: \(meeting.id)")
        lines.append("- Minutes で開く: minutes://meeting/\(meeting.id)")
        lines.append("- 日時: \(timeRange(meeting))")
        lines.append("- 状態: \(statusText(meeting))")
        if let calendar = meeting.calendarTitle, calendar != meeting.title { lines.append("- カレンダーの予定: \(calendar)") }
        if !meeting.attendees.isEmpty {
            lines.append("- 参加者（カレンダー）: " + meeting.attendees.map { attendee in attendee.email.map { "\(attendee.name) <\($0)>" } ?? attendee.name }.joined(separator: ", "))
        }
        let speakerLabels = speakers.filter { !$0.excluded }.map(names.label).uniqued()
        if !speakerLabels.isEmpty { lines.append("- 話者: \(speakerLabels.joined(separator: ", "))") }
        if !meeting.tags.isEmpty { lines.append("- タグ: \(meeting.tags.joined(separator: ", "))") }
        lines.append("- 言語: \(meeting.meetingLanguage == .en ? "英語" : "日本語")")
        if let folder = exportFolder(meeting) { lines.append("- 書き出し: \(folder.appendingPathComponent("meeting.md").path)") }
        if let note = try processingNote(meeting) {
            lines.append("")
            lines.append("> \(note)")
        }

        lines.append(contentsOf: ["", "## 要約", ""])
        if let summary = notes?.summaryMd, !summary.isEmpty {
            lines.append(summary)
        } else {
            lines.append(meeting.meetingStatus == .done ? "（要約なし。要約に失敗したか、要約しない設定です）" : "（まだありません）")
        }

        lines.append(contentsOf: ["", "## 決定事項", ""])
        let decisions = notes?.decisions ?? []
        lines.append(contentsOf: decisions.isEmpty ? ["（なし）"] : decisions.map { "- \($0.text)\(evidenceText($0.evidence))" })

        lines.append(contentsOf: ["", "## アクション", ""])
        let actions = notes?.actionItems ?? []
        if actions.isEmpty {
            lines.append("（なし）")
        } else {
            for action in actions {
                var detail = ["担当: \(action.owner == "me" ? "自分" : action.owner)", "種別: \(action.kind.rawValue)（\(kindText(action.kind))）", "期限: \(action.due ?? "なし")"]
                if let id = action.id { detail.append("ID: \(id)") }
                if action.manual == true { detail.append("手で追加") }
                lines.append("- [\(action.done == true ? "x" : " ")] \(action.text)")
                lines.append("  - " + detail.joined(separator: " / ") + evidenceText(action.evidence))
            }
        }

        lines.append(contentsOf: ["", "## 未決・論点", ""])
        let questions = notes?.openQuestions ?? []
        lines.append(contentsOf: questions.isEmpty ? ["（なし）"] : questions.map { "- \($0.text)\(evidenceText($0.evidence))" })

        if let userNotes = notes?.userNotesMd, !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(contentsOf: ["", "## 利用者のメモ", "", userNotes])
        }

        lines.append(contentsOf: ["", "## 全文", ""])
        if segments.isEmpty {
            lines.append("（まだありません）")
        } else if arguments["include_transcript"]?.boolValue == true {
            if display.source == .live { lines.append("（ライブ字幕。確定の文字起こしはまだありません）") }
            lines.append(contentsOf: segments.map { transcriptLine($0, names: names) })
        } else {
            let characters = segments.reduce(0) { $0 + $1.text.count }
            lines.append("発言 \(segments.count) 件・約 \(characters) 文字\(display.source == .live ? "（ライブ字幕）" : "")。get_transcript で読めます。")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - get_transcript

    func getTranscript(_ arguments: [String: JSONValue]) throws -> String {
        let meeting = try resolveMeeting(arguments["meeting_id"]?.stringValue)
        let start = max(arguments["start"]?.intValue ?? 0, 0)
        let limit = min(max(arguments["limit"]?.intValue ?? 400, 1), 2_000)
        let speakers = try store.speakers(meetingId: meeting.id)
        let display = try store.displaySegments(meetingId: meeting.id)
        let segments = BackgroundVoices.removingExcluded(display.segments, speakers: speakers)
        let names = SpeakerNames(speakers: speakers)
        var lines = ["# \(meeting.title) の全文", "", "- ID: \(meeting.id)", "- 日時: \(timeRange(meeting))"]
        if let note = try processingNote(meeting) { lines.append("- 状態: \(note)") }
        if display.source == .live, !segments.isEmpty { lines.append("- ライブ字幕です（確定の文字起こしはまだありません）") }
        guard !segments.isEmpty else {
            lines.append(contentsOf: ["", "（発言はまだありません）"])
            return lines.joined(separator: "\n")
        }
        guard start < segments.count else {
            throw MCPToolError("start（\(start)）が発言の数（\(segments.count)）を超えています")
        }
        let end = min(start + limit, segments.count)
        lines.append("- 発言 \(segments.count) 件のうち \(start + 1)〜\(end) 件目" + (end < segments.count ? "（続きは start: \(end)）" : ""))
        lines.append("")
        lines.append(contentsOf: segments[start..<end].map { transcriptLine($0, names: names) })
        return lines.joined(separator: "\n")
    }

    // MARK: - search_meetings

    func searchMeetings(_ arguments: [String: JSONValue]) throws -> String {
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            throw MCPToolError("query を指定してください")
        }
        let limit = min(max(arguments["limit"]?.intValue ?? 10, 1), 50)
        // ローカル専用の会議を落としても件数が足りるよう、多めに引く
        let results = try store.search(query, meetingLimit: limit * 3, hitsPerMeeting: 5)
            .filter { $0.meeting.privacy == .cloudOk }
            .prefix(limit)
        guard !results.isEmpty else { return "「\(query)」に当たる会議はありません。" }
        var lines = ["「\(query)」の検索結果: 会議 \(results.count) 件（新しい順）"]
        for result in results {
            let meeting = result.meeting
            lines.append(contentsOf: ["", "## \(meeting.title)", ""])
            lines.append("- ID: \(meeting.id)")
            lines.append("- 日時: \(timeRange(meeting))")
            var matched: [String] = []
            if result.titleMatched { matched.append("タイトル・参加者・タグ") }
            if result.notesMatched { matched.append("要約・メモ") }
            if !result.segmentHits.isEmpty { matched.append("本文 \(result.segmentHits.count) 件") }
            lines.append("- 当たった所: \(matched.joined(separator: "、"))")
            guard !result.segmentHits.isEmpty else { continue }
            let names = SpeakerNames(speakers: try store.speakers(meetingId: meeting.id))
            for hit in result.segmentHits {
                lines.append("")
                for segment in hit.context {
                    lines.append((segment.id == hit.segment.id ? "> " : "  ") + transcriptLine(segment, names: names))
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// ID の会議か、ID がなければ直前の会議。ローカル専用の会議は返さない。
    func resolveMeeting(_ rawId: String?) throws -> MeetingRecord {
        if let id = rawId?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            guard let meeting = try store.meeting(id: id) else { throw MCPToolError("会議が見つかりません（ID: \(id)）。list_meetings か search_meetings で ID を確かめてください") }
            guard meeting.privacy == .cloudOk else {
                throw MCPToolError("この会議はローカル専用（クラウドに送らない設定）なので読めません。Minutes の会議の画面でクラウドへの送信を許可すると読めるようになります")
            }
            return meeting
        }
        let recent = try store.listMeetings(.all, limit: 200).filter { $0.privacy == .cloudOk }
        // 録音中の会議より、終わった直後の会議を「直前の会議」とみなす
        guard let meeting = recent.first(where: { $0.meetingStatus != .recording }) ?? recent.first else {
            throw MCPToolError("読める会議がありません")
        }
        return meeting
    }

    /// 後処理中・録音中・失敗のときの説明。完了なら nil。
    func processingNote(_ meeting: MeetingRecord) throws -> String? {
        switch meeting.meetingStatus {
        case .done: return nil
        case .recording: return "録音中です。本文はライブ字幕で、要約は会議が終わってから作られます。"
        case .failed: return "後処理に失敗しています。Minutes の会議の画面からやり直せます。"
        case .finalizing:
            let running = try store.runs(meetingId: meeting.id).last { $0.runStatus == .running }
            let step = running.flatMap { PipelineStep(rawValue: $0.step) }.map(stepText)
            return "後処理中です\(step.map { "（\($0)）" } ?? "（順番待ち）")。文字起こし・要約が終わるまで、少し待ってから読み直してください。"
        }
    }

    func statusText(_ meeting: MeetingRecord) -> String {
        switch meeting.meetingStatus {
        case .recording: "録音中"
        case .finalizing: "後処理中"
        case .done: "完了"
        case .failed: "失敗"
        }
    }

    func stepText(_ step: PipelineStep) -> String {
        switch step {
        case .finalizeAudio: "音声の仕上げ"
        case .transcribeFinal: "文字起こし"
        case .mergeTracks, .resolveSpeakers: "話者の整理"
        case .summarize: "要約"
        case .store: "保存"
        case .export: "書き出し"
        case .notify: "通知"
        }
    }

    func kindText(_ kind: MinutesSummary.ActionKind) -> String {
        switch kind {
        case .ownCommitment: "自分の約束"
        case .theirTask: "相手の宿題"
        case .delegable: "任せられる"
        }
    }

    func evidenceText(_ ids: [Int]) -> String {
        ids.isEmpty ? "" : "（根拠: " + ids.map { "#\($0)" }.joined(separator: ", ") + "）"
    }

    func transcriptLine(_ segment: SegmentRecord, names: SpeakerNames) -> String {
        "[\(TimeFormatting.hms(segment.tStart))] #\(segment.id.map(String.init) ?? "-") \(names.name(for: segment)): \(segment.text)"
    }

    func timeRange(_ meeting: MeetingRecord) -> String {
        let day = formatter("yyyy-MM-dd（EEE）HH:mm")
        guard let ended = meeting.endedAt else { return day.string(from: meeting.startedAt) }
        let minutes = Int((ended.timeIntervalSince(meeting.startedAt) / 60).rounded())
        return "\(day.string(from: meeting.startedAt))〜\(formatter("HH:mm").string(from: ended))（\(minutes) 分）"
    }

    func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// YYYY-MM-DD（その日の 0 時。endOfDay なら翌日の 0 時）か ISO 8601。
    func parseDate(_ raw: String, endOfDay: Bool, field: String) throws -> Date {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = formatter("yyyy-MM-dd")
        day.locale = Locale(identifier: "en_US_POSIX")
        if let date = day.date(from: text) {
            guard endOfDay else { return date }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        throw MCPToolError("\(field) の日付を読めません（\(raw)）。YYYY-MM-DD か ISO 8601 で指定してください")
    }

    func firstLine(_ markdown: String) -> String? {
        let line = markdown.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#-*> ")) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }

    func exportFolder(_ meeting: MeetingRecord) -> URL? {
        guard let exportDirectory else { return nil }
        let folder = exportDirectory.appendingPathComponent(MeetingExporter.folderName(meeting: meeting), isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("meeting.md").path) ? folder : nil
    }
}

/// 発言の話者名（書き出しと同じ決め方: 発言単位の変更を優先し、なければクラスタの話者）。
struct SpeakerNames {
    let byId: [String: SpeakerRecord]
    let byCluster: [String: SpeakerRecord]

    init(speakers: [SpeakerRecord]) {
        byId = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        byCluster = Dictionary(speakers.map { ($0.clusterLabel, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func name(for segment: SegmentRecord) -> String {
        if let id = segment.speakerId, let speaker = byId[id] { return label(speaker) }
        if let cluster = segment.clusterLabel {
            if let speaker = byCluster[cluster] { return label(speaker) }
            return cluster == TrackMerger.micSpeakerLabel ? "自分" : cluster
        }
        return "?"
    }

    func label(_ speaker: SpeakerRecord) -> String {
        if let name = speaker.displayName, !name.isEmpty { return name }
        return speaker.clusterLabel == TrackMerger.micSpeakerLabel ? "自分" : speaker.clusterLabel
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
