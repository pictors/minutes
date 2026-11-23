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
}
