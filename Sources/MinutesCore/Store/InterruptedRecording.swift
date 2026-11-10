import Foundation

/// 録音の途中でアプリが終わった会議の扱い（SPEC §6.4）。起動時の復旧（`Store.recoverInterruptedMeetings`）が使う。
/// 会議が始まったかは録音のフォルダの印（`RecordingPhase`）で決める。DB の行は、録音準備だけでも会議でも同じ「録音中」になる。
enum InterruptedRecording {
    enum Plan: Equatable {
        /// 会議ではない（録音準備だけ）か、何も録れていない。行と音声を消す（準備中の自分の声を送らない）
        case discard
        /// 会議の録音。録れた長さで終了時刻を決め、後処理を依頼する
        case process(endedAt: Date)
        /// 会議かどうか分からない（印のない録音）。これまでどおり中断として残し、利用者が再実行を選ぶ。終了時刻は録れた長さにする
        case keepFailed(endedAt: Date?)
    }

    static func plan(for meeting: MeetingRecord, hasSegments: Bool) -> Plan {
        let directory = meeting.audioDirectoryURL
        let audioNames = [RecordingSession.systemSTTName, RecordingSession.micSTTName, RecordingSession.systemArchiveName, RecordingSession.micArchiveName]
        let hasAudio = directory.map { folder in audioNames.contains { fileSize(folder.appendingPathComponent($0)) > 0 } } ?? false
        // 録音が始まる前（許可の確認の途中など）に終わった
        guard hasAudio || hasSegments else { return .discard }
        let seconds = directory.flatMap { folder in
            [RecordingSession.systemSTTName, RecordingSession.micSTTName]
                .compactMap { InterruptedWAVRecovery.recordedSeconds(folder.appendingPathComponent($0)) }
                .max()
        }
        let origin = meeting.recordingStartedAt ?? meeting.startedAt
        let endedAt = seconds.map { max(origin.addingTimeInterval($0), meeting.startedAt) }
        switch directory.flatMap(RecordingPhase.read(in:)) {
        case .armed?:
            return .discard
        case .meeting?:
            // 文字起こしに使う WAV が読めなければ、議事録は作れない（AAC は閉じる前に終わると読めない）
            return endedAt.map { .process(endedAt: $0) } ?? .keepFailed(endedAt: nil)
        case nil:
            return .keepFailed(endedAt: endedAt)
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
