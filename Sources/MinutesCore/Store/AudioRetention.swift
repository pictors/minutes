import Foundation

/// 音声ファイルの保持ポリシー（SPEC §4.3 / §14）: 既定 30 日、export 完了後のみ削除。文字起こしは永続。
public enum AudioRetention {
    public struct Report: Sendable, Equatable {
        public var purgedMeetingIds: [String] = []
        public var freedBytes: Int = 0
    }

    public static let audioFileNames = [
        RecordingSession.systemArchiveName, RecordingSession.systemSTTName,
        RecordingSession.micArchiveName, RecordingSession.micSTTName,
        RecordingSession.systemSTTName + ".interrupted", RecordingSession.micSTTName + ".interrupted",
    ]

    /// アプリ管理下（`managedRoot` 配下）の会議フォルダは中間成果物ごと削除する。
    /// CLI で持ち込んだ外部フォルダは音声ファイルだけを消し、利用者のファイルに触れない。
    @discardableResult
    public static func purge(store: Store, retentionDays: Int, now: Date = Date(), managedRoot: URL? = nil) throws -> Report {
        var report = Report()
        guard retentionDays > 0 else { return report }
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        let managedPath = managedRoot?.standardizedFileURL.path
        for candidate in try store.listMeetings(.status(.done)) {
            let lease: MeetingLease
            do { lease = try store.acquireMeetingLease(candidate.id) }
            catch StoreError.meetingBusy { continue }
            defer { withExtendedLifetime(lease) {} }
            guard let meeting = try store.meeting(id: candidate.id), meeting.meetingStatus == .done else { continue }
            guard let ended = meeting.endedAt, ended < cutoff, let directory = meeting.audioDirectoryURL else { continue }
            guard try store.hasSuccessfulExport(meetingId: meeting.id) else { continue }
            var freed = 0
            var removedAny = false
            for name in audioFileNames {
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                freed += (try? AudioFileTools.fileSize(url)) ?? 0
                try FileManager.default.removeItem(at: url)
                removedAny = true
            }
            let isManaged = managedPath.map { directory.standardizedFileURL.path.hasPrefix($0 + "/") } ?? false
            if isManaged, FileManager.default.fileExists(atPath: directory.path) {
                // 本文は DB にあるので、文字起こし・要約の中間成果物も含めてフォルダごと消す
                try FileManager.default.removeItem(at: directory)
                removedAny = true
            }
            if removedAny {
                try store.clearAudioDirectory(id: meeting.id)
                report.purgedMeetingIds.append(meeting.id)
                report.freedBytes += freed
            }
        }
        return report
    }
}
