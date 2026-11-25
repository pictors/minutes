import Foundation
import MinutesKit

/// 会議の一覧の 1 行（端末の録音と、サーバーの録音を client_id で重ねたもの）。
struct MeetingItem: Identifiable, Equatable {
    var id: String
    var local: MinutesCloudUpload?
    var server: MinutesCloudRecording?

    /// 題名のない会議の出し方
    static let untitled = "無題の会議"

    var title: String? { server?.title ?? local?.title }
    var startedAt: Date { server?.startedAt ?? local?.startedAt ?? server?.createdAt ?? .distantPast }
    var durationSeconds: Double? { server?.durationSeconds ?? local?.durationSeconds }
    var isDone: Bool { server?.status == "done" }
    /// 同期を入れた Mac が上げた会議（音声はない。消すのは Mac。P7）
    var isMacMeeting: Bool { server?.isSyncedMeeting == true }
    /// 題名を直せる（サーバーにある会議。iPhone・Watch の会議も Mac の会議も。直したものは Mac にも届く。P7）
    var canRename: Bool { server != nil }
    /// 題名を空にできる（Mac の会議は題名を空にできない。サーバーが断る）
    var allowsEmptyTitle: Bool { !isMacMeeting }
    /// 消せる（Mac の会議は Mac で消す）。録音中の会議かは呼ぶ側で見る
    var canDelete: Bool { !isMacMeeting }
    /// リンクで共有できる録音（iPhone・Watch で録ってサーバーで処理が終わったものと、同期した Mac の会議。P7）
    var shareableRecording: MinutesCloudRecording? {
        guard let server, server.status == "done", server.isSyncedMeeting || ["iphone", "watch"].contains(server.source ?? "") else { return nil }
        return server
    }
    /// 録った機器（一覧の絞り込みと、会議の画面の記号と名前）
    var origin: MeetingOrigin {
        if isMacMeeting { return .mac }
        if server?.source == "watch" || local?.source == "watch" { return .watch }
        return .iphone
    }
}

/// 会議を録った機器。
enum MeetingOrigin: String, CaseIterable, Identifiable, Sendable {
    case iphone, watch, mac

    var id: String { rawValue }

    var name: String {
        switch self {
        case .iphone: "iPhone"
        case .watch: "Watch"
        case .mac: "Mac"
        }
    }

    var systemImage: String {
        switch self {
        case .iphone: "iphone"
        case .watch: "applewatch"
        case .mac: "laptopcomputer"
        }
    }

    var text: String { "\(name) で録音" }
}
