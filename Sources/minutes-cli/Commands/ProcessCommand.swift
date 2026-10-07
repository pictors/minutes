import Foundation
import MinutesCore

/// 録音フォルダに Phase 1 の後処理パイプライン（final 文字起こし → マージ → 要約 → 保存 → 書き出し）を掛ける。
/// アプリと同じ Store / パイプラインを使うので、実会議のフォルダで G3〜G5 を CLI から確認できる。
enum ProcessCommand {
    static let spec = ArgumentSpec(
        options: ["title", "privacy", "provider", "db", "export-dir", "sync-dir", "force", "locale", "language", "summary-language", "summary-provider", "summary-model", "codex-path", "claude-path"],
        flags: ["no-summary", "summary-only", "quiet"]
    )

    static func run(_ arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        guard let inputPath = parsed.positionals.first else { throw ArgumentError.missingPositional("recording-dir") }
        let directory = URL(fileURLWithPath: inputPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArgumentError.invalidValue(option: "recording-dir", value: inputPath, expected: "録音フォルダ")
        }
        let privacyRaw = parsed.value("privacy") ?? PrivacyMode.cloudOk.rawValue
        guard var privacy = PrivacyMode(rawValue: privacyRaw) else {
            throw ArgumentError.invalidValue(option: "privacy", value: privacyRaw, expected: "cloud_ok | local_only")
        }
        let locale = Locale(identifier: parsed.value("locale") ?? "ja-JP")
        // 会議の言語（省略すると、新しい会議は自動判定、既存の会議はそのまま）と要約の言語
        let language = try parsed.value("language").map { raw -> MeetingLanguage in
            guard let language = MeetingLanguage(rawValue: raw) else { throw ArgumentError.invalidValue(option: "language", value: raw, expected: "ja | en") }
            return language
        }
        let summaryLanguage = try parsed.value("summary-language").map { raw -> MeetingLanguage in
            guard let language = MeetingLanguage(rawValue: raw) else { throw ArgumentError.invalidValue(option: "summary-language", value: raw, expected: "ja | en") }
            return language
        }
        let quiet = parsed.has("quiet")
        let force = Set(parsed.list("force").compactMap { PipelineStep(rawValue: $0) })

        let store = try parsed.value("db").map { try Store.open(at: URL(fileURLWithPath: $0)) } ?? Store.open()
        let manifest = try? RecordingManifest.read(from: directory)

        // 既存の会議（同じ音声フォルダ）があれば再利用して再開する
        let existing = try store.listMeetings(.all, limit: 10_000).first { $0.audioDir == directory.path }
        if parsed.has("summary-only"), existing == nil {
            throw ArgumentError.invalidValue(option: "summary-only", value: inputPath, expected: "処理済み会議に紐づく録音フォルダ（音声削除済みの会議はアプリの要約更新を使用）")
        }
        let meeting: MeetingRecord
        if let existing {
            if parsed.value("privacy") == nil { privacy = existing.privacy }
            try store.updateMeetingMetadata(id: existing.id, title: parsed.value("title"), privacy: parsed.value("privacy") == nil ? nil : privacy)
            guard let current = try store.meeting(id: existing.id) else { throw PipelineError.meetingNotFound(existing.id) }
            meeting = current
            privacy = current.privacy
            Console.info("既存の会議を再利用: \(meeting.id)")
        } else {
            let startedAt = manifest?.startedAt ?? ((try? FileManager.default.attributesOfItem(atPath: directory.path)[.creationDate] as? Date) ?? Date())
            meeting = try store.createMeeting(MeetingRecord(
                id: manifest?.id.replacingOccurrences(of: "-", with: "").uppercased().prefix(26).description ?? ULID.generate(),
                title: parsed.value("title") ?? manifest?.title ?? directory.lastPathComponent,
                startedAt: startedAt,
                endedAt: manifest?.endedAt,
                privacyMode: privacy,
                status: .finalizing,
                audioDir: directory.path
            ))
            Console.info("会議を作成: \(meeting.id) (\(meeting.title))")
        }
        if let language, MeetingLanguage(code: meeting.language) != language || meeting.languageDetected {
            // 言語を変えたら本文の編集を外して文字起こしし直す（アプリの会議の画面と同じ）
            try store.prepareRetranscription(meetingId: meeting.id)
            try store.setMeetingLanguage(id: meeting.id, language: language, detected: false)
        }
        if let summaryLanguage { try store.setSummaryLanguage(id: meeting.id, language: summaryLanguage) }

        let providerName = parsed.value("provider") ?? "elevenlabs"
        let cloud: (any BatchTranscriber)?
        switch providerName {
        case "local": cloud = nil
        default: cloud = privacy == .localOnly || parsed.has("summary-only") ? nil : try TranscribeCommand.makeProvider(providerName, locale: locale, numSpeakers: nil, clusterThreshold: nil, status: { _ in })
        }
        let status: @Sendable (String) -> Void = { message in if !quiet { Console.info("[local] \(message)") } }
        let local = LocalTranscriber(locale: locale, onStatus: status)
        var settings = AppSettings.load()
        if let raw = parsed.value("summary-provider") {
            guard let provider = SummaryProvider(rawValue: raw) else {
                throw ArgumentError.invalidValue(option: "summary-provider", value: raw, expected: "codex | claude-code | anthropic | none")
            }
            settings.summaryProvider = provider
        }
        if let model = parsed.value("summary-model") {
            switch settings.resolvedSummaryProvider {
            case .codex: settings.codexModel = model
            case .claudeCode: settings.claudeCodeModel = model
            case .anthropic: settings.summaryModel = model
            case .none: break
            }
        }
        if let path = parsed.value("codex-path") { settings.codexExecutablePath = path }
        if let path = parsed.value("claude-path") { settings.claudeCodeExecutablePath = path }
        var summarizer: (any Summarizing)? = nil
        if !parsed.has("no-summary"), privacy == .cloudOk {
            summarizer = try SummaryProviders.make(settings: settings)
        }
        let exportDirectory = parsed.value("export-dir").map { URL(fileURLWithPath: $0) } ?? AppSettings.load().exportDirectoryURL
        var targets: [any SyncTarget] = []
        if let sync = parsed.value("sync-dir") { targets.append(LocalDirectorySyncTarget(destination: URL(fileURLWithPath: sync))) }
        let providers = PipelineProviders(
            cloud: cloud, local: local, summarizer: summarizer, exportDirectory: exportDirectory, syncTargets: targets,
            englishSummaryLanguage: summaryLanguage ?? settings.englishSummaryLanguage,
            notify: { meeting, notes in Console.out("通知: 議事録ができました — \(meeting.title)\(notes == nil ? "（要約なし）" : "")") },
            onProgress: { _, step, message in Console.info("[\(step.rawValue)] \(message)") }
        )
        let pipeline = PostProcessPipeline(store: store, providers: providers)
        if parsed.has("summary-only") {
            try await pipeline.regenerateSummary(meetingId: meeting.id)
            Console.out("要約を更新しました: \(meeting.id)")
            return
        }
        let started = Date()
        let outcome = try await pipeline.run(meetingId: meeting.id, force: force)

        Console.out("")
        Console.out("== 後処理サマリ ==")
        Console.out(String(format: "elapsed: %.1f s (G3 目標: 会議終了から 5 分以内)", Date().timeIntervalSince(started)))
        Console.out("executed: \(outcome.executed.map(\.rawValue).joined(separator: ", "))")
        if !outcome.skipped.isEmpty { Console.out("skipped: \(outcome.skipped.map(\.rawValue).joined(separator: ", "))") }
        for (step, message) in outcome.warnings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            Console.out("warning: \(step.rawValue) に失敗しました（会議は完了扱い）: \(message)")
        }
        for step in PipelineStep.allCases {
            if let run = try store.latestRun(meetingId: meeting.id, step: step.rawValue), run.runStatus == .ok, let provider = run.provider {
                Console.out("  \(step.rawValue): \(provider)")
            }
        }
        let finals = try store.segments(meetingId: meeting.id, source: .final)
        let speakers = try store.speakers(meetingId: meeting.id)
        Console.out("segments: \(finals.count)  speakers: \(speakers.map(\.label).joined(separator: ", "))")
        if let notes = try store.notes(meetingId: meeting.id), let summary = notes.summaryMd {
            Console.out("summary (\(notes.model ?? "-")):")
            Console.out(summary.split(separator: "\n").prefix(8).map { "  " + $0 }.joined(separator: "\n"))
            Console.out("decisions: \(notes.decisions.count)  actions: \(notes.actionItems.count)  open questions: \(notes.openQuestions.count)")
        }
        if let path = outcome.exportPath { Console.out("export: \(path)") }
        Console.out("db: \(parsed.value("db") ?? Store.defaultURL().path)")
        Console.out("app link: minutes://meeting/\(meeting.id)")
    }
}
