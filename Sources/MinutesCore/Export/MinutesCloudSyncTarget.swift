import Foundation

/// Minutes クラウドへの会議の同期（P7、SPEC §5.6）。同期を入れた Mac が、会議の文字起こしと議事録をサーバーに置き、iPhone で読めるようにする。
/// - 送るもの: 題名・日時・言語・長さ、文字起こし（話者はラベル "me"・"spk_0" などで指し、名前は speakers[].name）、議事録（要約・決まったこと・
///   やることとその済み・確かめること）。音声・メモ・ライブ字幕は送らない。背景の声として外した話者の発言は送らない（書き出しと同じ）。
/// - 送らない会議: ローカルのみ（書き出しそのものをしない）と、iPhone・Watch から取り込んだ会議（サーバーにもとの録音がある）。
/// - 同期を切っているあいだも、この同期先は置いておく（`uploads` が false）。ローカルのみにした会議と、消した会議をサーバーから消すため。
/// - サーバーの会議は、Mac の会議の ID（`PUT /v1/meetings/:id`）で指す。上げるたびに丸ごと置き換える（正は Mac）。
///   iPhone で直した題名・話者の名前は `CloudEditSync` が手元に当てる。上げ直しには、直しの記録を読んだところ（edits_seen）を付け、
///   サーバーは、まだ読んでいない直しを上げ直しの上からかぶせ直す（古い題名・名前で iPhone の直しを消さない）。
public struct MinutesCloudSyncTarget: SyncTarget {
    public static let targetID = "minutes_cloud"

    public let id = MinutesCloudSyncTarget.targetID
    public var client: MinutesCloudClient
    /// 同期を入れているか（切っているときは送らず、消すことだけをする）
    public var uploads: Bool
    public var timeZone: TimeZone
    /// 直しの記録を読んだところ（`CloudEditSync.editsSeen`）。nil なら上げ直しに付けない
    public var editsSeen: (@Sendable () -> Int?)?

    public init(client: MinutesCloudClient, uploads: Bool, timeZone: TimeZone = .current, editsSeen: (@Sendable () -> Int?)? = nil) {
        self.client = client
        self.uploads = uploads
        self.timeZone = timeZone
        self.editsSeen = editsSeen
    }

    /// 書き出しの指紋に入れる値。同期を入れる・切るで変える（入れたときは送り直し、切ったときは送らない）
    public var cacheIdentity: String { "\(id)/\(client.baseURL.host() ?? "")/\(uploads ? "on" : "off")" }

    public func accepts(_ meeting: MeetingRecord) -> Bool {
        uploads && meeting.cloudRecordingId == nil
    }

    /// フォルダだけでは送れない（話者のラベルと名前は DB の中身から作る）。
    public func upload(folder: URL, manifest: ExportManifest) async throws -> SyncReceipt {
        throw MinutesCloudSyncError.needsDatabaseContent
    }

    public func upload(export: SyncExport) async throws -> SyncReceipt {
        var upload = Self.payload(export.input, timeZone: timeZone)
        upload.editsSeen = editsSeen?()
        let recording = try await client.putMeeting(id: export.input.meeting.id, upload: upload)
        return SyncReceipt(targetId: id, location: "minutes-cloud:\(recording.id)", checksum: export.manifest.checksum, uploadedAt: Date())
    }

    /// ローカルのみにした会議をサーバーから消す（もうなければ、それでよい）。
    public func remove(meeting: MeetingRecord) async throws -> [String] {
        try await deleteIfPresent(meeting.id)
        return ["minutes-cloud:meeting:\(meeting.id)"]
    }

    /// 消した会議をサーバーから消す（もうなければ、それでよい）。
    public func removeDeleted(meetingID: String) async throws {
        try await deleteIfPresent(meetingID)
    }

    /// 消す要求の 404 は、サーバーにもうないということ（アカウントを作り直した・すでに消えた会議・同期のないサーバー）なので、消えたものとして扱う。
    /// 待たせたままにすると、毎回 404 になり、`haltsRetries` でその回の残りの消す処理まで止まる（2026-11-25）。
    private func deleteIfPresent(_ meetingID: String) async throws {
        do {
            try await client.deleteMeeting(id: meetingID)
        } catch let error as MinutesCloudError where error.status == 404 {
            return
        }
    }

    /// ログイン切れ・有料でない・混雑・サーバーの誤り・回線は、ほかの会議でも同じなので、この回の残りを送らない。
    /// 送るときの 404 も同じ（会議の ID の形はいつも通るので、404 はサーバーにこの道がない＝同期のないサーバー）。消すときの 404 は `deleteIfPresent` が消えたものとして扱う。
    public func haltsRetries(_ error: Error) -> Bool {
        if error is URLError || error is CancellationError { return true }
        guard let cloud = error as? MinutesCloudError else { return false }
        if case .notSignedIn = cloud { return true }
        guard let status = cloud.status else { return false }
        return status == 401 || status == 402 || status == 404 || status == 429 || status >= 500
    }

    /// この会議の形をサーバーが受けない（400 bad_meeting・413 大きすぎる・409）。送り直しても通らない。
    public func isPermanentFailure(_ error: Error) -> Bool {
        guard let status = (error as? MinutesCloudError)?.status else { return false }
        return status == 400 || status == 409 || status == 413 || status == 422
    }

    /// サーバーへ送る本文。文字起こしは iPhone・Watch の録音の transcript.json と同じ形（話者はラベルで指す）。
    public static func payload(_ input: MeetingExporter.Input, timeZone: TimeZone) -> MinutesCloudMeetingUpload {
        let meeting = input.meeting
        let speakers = input.speakers.filter { !$0.excluded }
        let segments = BackgroundVoices.removingExcluded(input.segments, speakers: input.speakers)
        let speakerByID = Dictionary(uniqueKeysWithValues: input.speakers.map { ($0.id, $0) })
        func label(for segment: SegmentRecord) -> String? {
            if let id = segment.speakerId, let speaker = speakerByID[id] { return speaker.clusterLabel }
            return segment.clusterLabel
        }
        func track(_ label: String?) -> String { label == TrackMerger.micSpeakerLabel ? TrackMerger.micTrack : TrackMerger.systemTrack }
        let recorded = input.segments.map(\.tEnd).max()
        let duration = meeting.endedAt.map { max(0, $0.timeIntervalSince(meeting.startedAt)) } ?? recorded
        let document = TranscriptDocument(
            meeting: .init(id: meeting.id, title: meeting.title, startedAt: meeting.startedAt, durationSeconds: duration, sourceDirectory: nil),
            provider: input.providerDescription,
            language: meeting.meetingLanguage.rawValue,
            speakers: speakers.map { .init(label: $0.clusterLabel, name: $0.displayName, providerLabel: nil, track: track($0.clusterLabel)) },
            segments: segments.map { segment in
                let speaker = label(for: segment)
                return .init(id: Int(segment.id ?? 0), track: track(speaker), tStart: segment.tStart, tEnd: segment.tEnd, speaker: speaker, text: segment.text, confidence: segment.confidence)
            },
            providerMeta: [:],
            createdAt: Date()
        )
        return MinutesCloudMeetingUpload(
            title: meeting.title,
            startedAt: meeting.startedAt,
            timeZone: timeZone.identifier,
            language: meeting.meetingLanguage.rawValue,
            durationSeconds: duration,
            transcript: document,
            summary: input.notes?.summary
        )
    }
}

public enum MinutesCloudSyncError: Error, LocalizedError, Equatable {
    case needsDatabaseContent

    public var errorDescription: String? {
        switch self {
        case .needsDatabaseContent: "Minutes クラウドへの同期は、会議のフォルダだけでは送れません"
        }
    }
}
