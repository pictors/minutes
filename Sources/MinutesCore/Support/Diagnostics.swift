import Foundation
import GRDB

/// 診断情報の書き出し（SPEC §12 Phase 1.5「初めての人の導線」）。問い合わせに添付するための JSON。
/// 版・環境・許可・プロバイダの状態・後処理の結果・録音の統計を入れ、本文・音声・API キーは入れない。
/// イベントログとエラーに出る会議名は会議の ID に置き換える（2026-10-05 決定）。利用状況の送信（テレメトリ）はしない。
public struct DiagnosticsReport: Encodable, Sendable {
    public var generatedAt: Date
    public var app: [String: String]
    public var system: [String: String]
    public var permissions: [String: String]
    public var providers: [String: String]
    public var settings: [String: String]
    public var session: [String: String]
    public var events: [String]
    public var meetings: [Meeting]

    public struct Meeting: Encodable, Sendable {
        public var id: String
        public var startedAt: Date
        public var endedAt: Date?
        public var status: String
        public var privacy: String
        public var platform: String?
        /// 段階ごとの最後の結果（pipeline_runs）。
        public var steps: [Step]
        /// 録音フォルダの recording.json から（音声の保持期限を過ぎると消える）。
        public var recording: Recording?
    }

    public struct Step: Encodable, Sendable {
        public var step: String
        public var status: String
        public var provider: String?
        public var startedAt: Date?
        public var finishedAt: Date?
        public var error: String?
    }

    public struct Recording: Encodable, Sendable {
        public var durationSeconds: Double?
        public var targetBundleIdentifiers: [String]
        /// 実際に録った会議アプリ（bundle ID）。プロセス名とデバイス名は入れない。
        public var tappedBundleIdentifiers: [String]
        public var tracks: [String: Track]
        public var resourceUsage: ResourceUsageSummary?
    }

    public struct Track: Encodable, Sendable {
        public var sourceSampleRate: Double
        public var sourceChannels: Int
        public var receivedSeconds: Double
        public var activeSeconds: Double
        public var gapCount: Int
        public var gapSeconds: Double
        public var tailPaddingSeconds: Double?
        public var formatChanges: Int
        public var failure: String?
    }

    /// アプリが集める環境（版・OS・許可・プロバイダの状態など）。値は表示用の短い文字列。
    public struct Environment: Sendable {
        public var app: [String: String]
        public var system: [String: String]
        public var permissions: [String: String]
        public var providers: [String: String]
        public var session: [String: String]

        public init(app: [String: String] = [:], system: [String: String] = [:], permissions: [String: String] = [:],
                    providers: [String: String] = [:], session: [String: String] = [:]) {
            self.app = app
            self.system = system
            self.permissions = permissions
            self.providers = providers
            self.session = session
        }
    }

    /// 直近 `limit` 件の会議と、渡されたイベントログ・環境から組み立てる。
    public static func collect(store: Store, settings: AppSettings, events: [String], environment: Environment,
                               now: Date = Date(), limit: Int = 20) throws -> DiagnosticsReport {
        let meetings = try store.writer.read { db in try Store.fetchMeetings(db, filter: .all, limit: 10_000) }
        let redactor = TitleRedactor(meetings: meetings.map { ($0.id, [$0.title, $0.calendarTitle].compactMap { $0 }) })
        var recent: [Meeting] = []
        for meeting in meetings.prefix(limit) {
            var latest: [String: PipelineRunRecord] = [:]
            var order: [String] = []
            for run in try store.runs(meetingId: meeting.id) {
                if latest[run.step] == nil { order.append(run.step) }
                latest[run.step] = run
            }
            let steps = order.compactMap { latest[$0] }.map { run in
                Step(step: run.step, status: run.status, provider: run.provider.map(redactor.redact), startedAt: run.startedAt,
                     finishedAt: run.finishedAt, error: run.error.map(redactor.redact))
            }
            recent.append(Meeting(id: meeting.id, startedAt: meeting.startedAt, endedAt: meeting.endedAt, status: meeting.status,
                                  privacy: meeting.privacyMode, platform: meeting.platform, steps: steps,
                                  recording: meeting.audioDir.flatMap { recording(in: URL(fileURLWithPath: $0, isDirectory: true)) }))
        }
        return DiagnosticsReport(generatedAt: now, app: environment.app, system: environment.system, permissions: environment.permissions,
                                 providers: environment.providers, settings: summary(of: settings), session: environment.session,
                                 events: events.map(redactor.redact), meetings: recent)
    }

    /// 録音の統計だけを読む（会議名・プロセス名・デバイス名・イベントは入れない）。
    static func recording(in directory: URL) -> Recording? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(RecordingManifest.fileName)),
              let manifest = try? JSONCoding.decoder().decode(RecordingManifest.self, from: data) else { return nil }
        let tracks = manifest.tracks.mapValues { stats in
            Track(sourceSampleRate: stats.sourceSampleRate, sourceChannels: stats.sourceChannels, receivedSeconds: stats.receivedSeconds,
                  activeSeconds: stats.activeSeconds, gapCount: stats.gapCount, gapSeconds: stats.gapSeconds,
                  tailPaddingSeconds: stats.tailPaddingSeconds, formatChanges: stats.formatChanges,
                  failure: stats.failure.map { String(describing: $0) })
        }
        return Recording(durationSeconds: manifest.durationSeconds, targetBundleIdentifiers: manifest.targetBundleIdentifiers,
                         tappedBundleIdentifiers: Array(Set(manifest.tappedProcesses.compactMap(\.bundleID))).sorted(),
                         tracks: tracks, resourceUsage: manifest.resourceUsage)
    }

    /// 設定のうち、不具合の切り分けに使うものだけ。自分の名前・告知文・フォルダの場所は入れない（有無だけ）。
    static func summary(of settings: AppSettings) -> [String: String] {
        var result: [String: String] = [
            "target_bundle_identifiers": settings.targetBundleIdentifiers.joined(separator: ", "),
            "final_provider": settings.finalProviderId,
            "summary_provider": settings.resolvedSummaryProvider.rawValue,
            "default_privacy_mode": settings.defaultPrivacyMode.rawValue,
            "audio_retention_days": String(settings.audioRetentionDays),
            "export_directory": settings.exportDirectory == nil ? "既定" : "指定あり",
            "sync_directory": settings.syncDirectory == nil ? "なし" : "指定あり",
            "calendars": settings.calendarIdentifiers.isEmpty ? "すべて" : "\(settings.calendarIdentifiers.count) 件を選択",
            "auto_start_on_audio": String(settings.autoStartOnAudio),
            "confirm_before_auto_start": String(settings.confirmBeforeAutoStart),
            "silence_timeout_seconds": String(Int(settings.silenceTimeoutSeconds)),
            "keyterms_auto_learn": String(settings.keytermsAutoLearn),
            "meeting_language": settings.meetingLanguage.rawValue,
            "english_summary_language": settings.englishSummaryLanguage.rawValue,
            "include_mic": String(settings.includeMic),
            "mic_device": settings.micDevice == nil ? "既定の入力" : "指定あり",
            "global_shortcut": settings.globalShortcut?.display ?? "なし",
            "appearance": settings.appearance.rawValue,
            "onboarding_completed": settings.onboardingCompletedAt == nil ? "未" : "済",
        ]
        switch settings.resolvedSummaryProvider {
        case .codex: result["summary_model"] = settings.codexModel ?? "Codex の既定"
        case .claudeCode: result["summary_model"] = settings.claudeCodeModel ?? "Claude Code の既定"
        case .anthropic: result["summary_model"] = settings.summaryModel
        case .none: break
        }
        return result
    }
}

/// 会議名（とカレンダーの件名）を会議の ID に置き換える。長い名前から置き換え、1 文字の名前は置き換えない（ほかの語まで消さない）。
public struct TitleRedactor: Sendable {
    private let replacements: [(title: String, label: String)]

    public init(meetings: [(id: String, titles: [String])]) {
        var pairs: [(title: String, label: String)] = []
        for meeting in meetings {
            let label = "〔会議 \(meeting.id)〕"
            for title in meeting.titles {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2 else { continue }
                pairs.append((trimmed, label))
            }
        }
        replacements = pairs.sorted { $0.title.count > $1.title.count }
    }

    public func redact(_ text: String) -> String {
        var result = text
        for (title, label) in replacements where result.contains(title) {
            result = result.replacingOccurrences(of: title, with: label)
        }
        return result
    }
}
