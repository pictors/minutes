import Foundation
import MinutesKit

/// 会議の一覧の 1 行（端末の録音と、サーバーの録音を client_id で重ねたもの）。
struct MeetingItem: Identifiable, Equatable {
    var id: String
    var local: MinutesCloudUpload?
    var server: MinutesCloudRecording?

    var title: String? { server?.title ?? local?.title }
    var startedAt: Date { server?.startedAt ?? local?.startedAt ?? server?.createdAt ?? .distantPast }
    var durationSeconds: Double? { server?.durationSeconds ?? local?.durationSeconds }
    var isDone: Bool { server?.status == "done" }
    /// 同期を入れた Mac が上げた会議（音声はない。直す・消すのは Mac。P7）
    var isMacMeeting: Bool { server?.isSyncedMeeting == true }
    /// 録った機器の記号と名前（一覧と会議の画面）
    var origin: (systemImage: String, text: String) {
        if isMacMeeting { return ("laptopcomputer", "Mac で録音") }
        if server?.source == "watch" || local?.source == "watch" { return ("applewatch", "Watch で録音") }
        return ("iphone", "iPhone で録音")
    }
}
