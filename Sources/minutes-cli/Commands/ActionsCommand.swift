import Foundation
import MinutesCore

/// 会議のやることを見る・済みを付ける・外す（P7 の済みの同期。SPEC §5.6）。
///   minutes-cli actions <会議の ID> [--db <path>] [--add <本文>] [--done <やることの ID>] [--undone <やることの ID>] [--sync]
/// 済みを変えると、サーバーにある会議（iPhone・Watch から取り込んだ会議、同期した会議）なら送る列に入る。--add は手でやることを足す（アプリと同じ）。
/// --sync でサーバーへ送り、iPhone・ほかの Mac で付けた済みを手元の会議に重ねる（同期した会議も含める。アプリは同期を入れているときだけ）。
/// 本文は先頭 40 文字だけ出す。
enum ActionsCommand {
    static let spec = ArgumentSpec(options: ["db", "add", "done", "undone"], flags: ["sync"])

    static func run(_ arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        guard let meetingId = parsed.positionals.first else { throw ArgumentError.missingPositional("会議の ID") }
        let store = try parsed.value("db").map { try Store.open(at: URL(fileURLWithPath: $0)) } ?? Store.open()
        guard try store.meeting(id: meetingId) != nil else { throw StoreError.notFound(meetingId) }

        for text in parsed.values("add") {
            _ = try store.addManualAction(meetingId: meetingId, text: text)
            Console.out("足しました: \(Log.preview(text))")
        }
        if let actionId = parsed.value("done") ?? parsed.value("undone") {
            let done = parsed.value("done") != nil
            guard let action = try store.notes(meetingId: meetingId)?.actionItems.first(where: { $0.id == actionId }) else {
                throw StoreError.notFound("やること \(actionId)")
            }
            _ = try store.setActionCompletion(meetingId: meetingId, action: action, done: done)
            Console.out("\(done ? "済みにしました" : "済みを外しました"): \(actionId)（サーバーへ送るのを待っている済み \(try store.pendingCloudActionPushCount()) 件）")
        }

        if parsed.has("sync") {
            guard MinutesCloudCredentials.isSignedIn else { throw MinutesCloudError.notSignedIn }
            let report = await CloudActionSync.sync(client: .standard(), store: store, includesMacMeetings: true)
            Console.out("同期: 送った \(report.pushed) 件、送らなかった \(report.dropped) 件、重ねた \(report.applied) 件")
            if let interruption = report.interruption { Console.out("途中でやめました（残りは次の同期で続けます）: \(interruption)") }
        }

        let actions = try store.notes(meetingId: meetingId)?.actionItems ?? []
        Console.out("やること: \(actions.count) 件")
        for action in actions {
            Console.out("  [\(action.done == true ? "x" : " ")] \(action.id ?? "-")  \(Log.preview(action.text))")
        }
    }
}
