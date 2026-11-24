import Foundation
import MinutesCore

/// この Mac の会議を Minutes クラウドへ同期する（P7。アプリの設定の「この Mac の会議を iPhone でも読む」と同じ送り方）。
///   minutes-cli sync [--db <path>] [--export-dir <dir>] [--meeting <id>] [--delete <id>]
/// 会議を指さなければ、同期を入れたときと同じく、終わった・クラウド OK・取り込んだ会議でない会議をすべて送る。
/// 消した会議・ローカルのみにした会議の、サーバーからの削除（待っているもの）も行う。--delete はサーバーの会議だけを消す（この Mac の会議は消さない）。
/// ログインは `minutes-cli account login`（または環境変数 MINUTES_CLOUD_TOKEN）。サーバーの場所は MINUTES_CLOUD_BASE_URL で変えられる。
enum SyncCommand {
    static let spec = ArgumentSpec(options: ["db", "export-dir", "meeting", "delete"], flags: ["quiet"])

    static func run(_ arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        guard MinutesCloudCredentials.isSignedIn else { throw MinutesCloudError.notSignedIn }
        let store = try parsed.value("db").map { try Store.open(at: URL(fileURLWithPath: $0)) } ?? Store.open()
        let settings = AppSettings.load()
        let target = MinutesCloudSyncTarget(client: .standard(), uploads: true)
        if let id = parsed.value("delete") {
            try await target.removeDeleted(meetingID: id)
            Console.out("サーバーから消しました: \(id)")
            return
        }
        let providers = PipelineProviders(
            cloud: nil, local: LocalTranscriber(), summarizer: nil,
            exportDirectory: parsed.value("export-dir").map { URL(fileURLWithPath: $0) } ?? settings.exportDirectoryURL,
            syncTargets: [target]
        )
        let pipeline = PostProcessPipeline(store: store, providers: providers)
        let ids = try parsed.value("meeting").map { [$0] } ?? store.meetingIdsForCloudSync()
        try store.queueExports(meetingIds: ids, target: MinutesCloudSyncTarget.targetID)
        let report = await pipeline.retryPendingExports()
        let removals = await pipeline.retryPendingRemovals()
        for line in report + removals { Console.out(line) }
        Console.out("送った会議: \(report.filter { $0.hasSuffix(": ok") }.count) / \(ids.count) 件、サーバーから消した会議: \(removals.filter { $0.hasSuffix(": removed") }.count) 件")
    }
}
