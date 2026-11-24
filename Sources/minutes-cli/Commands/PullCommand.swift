import Foundation
import MinutesCore

/// サーバーの会議（iPhone・Apple Watch で録って、サーバーで文字起こしと要約をしたもの）を取り込み、アプリと同じ後処理に掛ける（SPEC §4.5）。
///   minutes-cli pull [--db <path>] [--audio-root <dir>] [--export-dir <dir>] [--sync-dir <dir>] [--no-process]
/// ログインは `minutes-cli account login`（または環境変数 MINUTES_CLOUD_TOKEN）。サーバーの場所は MINUTES_CLOUD_BASE_URL で変えられる。
/// 文字起こしと要約はサーバーのものをそのまま使う（この Mac の文字起こし・要約の手段は呼ばない）。同じ録音は二重に取り込まない。
enum PullCommand {
    static let spec = ArgumentSpec(options: ["db", "audio-root", "export-dir", "sync-dir"], flags: ["no-process", "quiet"])

    static func run(_ arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        guard MinutesCloudCredentials.isSignedIn else { throw MinutesCloudError.notSignedIn }
        let quiet = parsed.has("quiet")
        let store = try parsed.value("db").map { try Store.open(at: URL(fileURLWithPath: $0)) } ?? Store.open()
        let settings = AppSettings.load()
        let audioRoot = parsed.value("audio-root").map { URL(fileURLWithPath: $0, isDirectory: true) } ?? settings.audioRootDirectoryURL

        let report = try await CloudMeetingImport.pull(client: .standard(), store: store, audioRoot: audioRoot)
        Console.out("取り込み: \(report.imported.count) 件（サーバーで処理中 \(report.pending) 件、取り込めず \(report.failures.count) 件）")
        for failure in report.failures { Console.out("  取り込めません: \(failure.recordingID) — \(failure.message)") }
        if let interruption = report.interruption { Console.out("途中でやめました（残りは次の取り込みで続けます）: \(interruption)") }
        guard !parsed.has("no-process") else {
            for meeting in report.imported { Console.out("  \(meeting.id)  \(meeting.title)（後処理はまだ）") }
            return
        }

        var targets: [any SyncTarget] = []
        if let sync = parsed.value("sync-dir") { targets.append(LocalDirectorySyncTarget(destination: URL(fileURLWithPath: sync))) }
        // 取り込んだ会議はサーバーの文字起こしと要約を使うので、文字起こし・要約の手段は渡さない
        let providers = PipelineProviders(
            cloud: nil, local: LocalTranscriber(), summarizer: nil,
            exportDirectory: parsed.value("export-dir").map { URL(fileURLWithPath: $0) } ?? settings.exportDirectoryURL,
            syncTargets: targets,
            onProgress: { _, step, message in if !quiet { Console.info("[\(step.rawValue)] \(message)") } }
        )
        let pipeline = PostProcessPipeline(store: store, providers: providers)
        for meeting in report.imported {
            let outcome = try await pipeline.run(meetingId: meeting.id)
            let segments = try store.segments(meetingId: meeting.id, source: .final)
            let speakers = try store.speakers(meetingId: meeting.id)
            let notes = try store.notes(meetingId: meeting.id)
            Console.out("")
            Console.out("\(meeting.id)  \(meeting.title)（\(meeting.platform ?? "-")、サーバーの録音 \(meeting.cloudRecordingId ?? "-")）")
            Console.out("  segments: \(segments.count)  speakers: \(speakers.map(\.label).joined(separator: ", "))")
            if let notes, notes.summaryMd != nil {
                Console.out("  summary (\(notes.model ?? "-")): decisions \(notes.decisions.count)  actions \(notes.actionItems.count)  open questions \(notes.openQuestions.count)")
            } else {
                Console.out("  summary: なし")
            }
            for (step, message) in outcome.warnings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                Console.out("  warning: \(step.rawValue) に失敗しました（会議は完了扱い）: \(message)")
            }
            for step in [PipelineStep.transcribeFinal, .summarize] {
                if let run = try store.latestRun(meetingId: meeting.id, step: step.rawValue), let provider = run.provider {
                    Console.out("  \(step.rawValue): \(provider)")
                }
            }
            if let path = outcome.exportPath { Console.out("  export: \(path)") }
        }
        Console.out("")
        Console.out("db: \(parsed.value("db") ?? Store.defaultURL().path)")
    }
}
