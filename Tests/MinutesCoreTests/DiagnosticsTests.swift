import Foundation
@testable import MinutesCore
import Testing

@Suite("診断情報 / 初回の案内の設定 / 要約しない")
struct DiagnosticsTests {
    @Test("会議名とカレンダーの件名を会議の ID に置き換える。長い名前から、1 文字の名前は置き換えない")
    func redactor() {
        let redactor = TitleRedactor(meetings: [
            (id: "A1", titles: ["週次定例", "週次定例 A社"]),
            (id: "B2", titles: ["朝会", "x"]),
        ])
        #expect(redactor.redact("armed: 週次定例 A社") == "armed: 〔会議 A1〕")
        #expect(redactor.redact("recording started: 朝会 / 週次定例") == "recording started: 〔会議 B2〕 / 〔会議 A1〕")
        // 1 文字の名前（x）でほかの語を消さない
        #expect(redactor.redact("export: index.md") == "export: index.md")
    }

    @Test("書き出す JSON に会議名・本文・自分の名前・告知文・フォルダの場所・デバイス名が入らない")
    func report() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audioDir = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        var system = TrackStatsSnapshot(name: "system", sourceSampleRate: 48_000, sourceChannels: 2, archiveSampleRate: 48_000,
                                        receivedFrames: 0, receivedSeconds: 60, writtenSeconds: 60, firstChunkOffsetSeconds: 0,
                                        gapCount: 2, gapSeconds: 1.5, overlapCount: 0, overlapSeconds: 0, formatChanges: 1,
                                        lastRmsDb: -40, intervalPeakRmsDb: -20, activeSeconds: 40, lastChunkTimelineEnd: 60)
        system.tailPaddingSeconds = nil
        let manifest = RecordingManifest(schemaVersion: 1, id: "rec", title: "A社との週次定例", startedAt: Date(), endedAt: Date(), durationSeconds: 60,
                                         targetBundleIdentifiers: ["com.google.Chrome"], allSystemAudio: false,
                                         tappedProcesses: [AudioProcessInfo(objectID: 1, pid: 42, bundleID: "com.google.Chrome", name: "Google Chrome Helper",
                                                                            parentPID: nil, isRunningOutput: true, isRunningInput: false)],
                                         clockDevice: "山田の AirPods", micDevice: "山田の AirPods", tapStream: nil, files: [:],
                                         tracks: ["system": system], resourceUsage: ResourceUsageSummary(cpuPercentAvg: 9, cpuPercentMax: 30, rssMaxBytes: 1, sampleCount: 10),
                                         events: ["armed: A社との週次定例"])
        try manifest.write(to: audioDir)

        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "A社との週次定例", startedAt: Date(), calendarTitle: "A社 定例",
                                                            privacyMode: .cloudOk, status: .done, audioDir: audioDir.path))
        try store.appendSegments([SegmentRecord(meetingId: meeting.id, source: .final, tStart: 0, tEnd: 1, text: "売上の見込みを共有します")])
        _ = try store.recordRun(meetingId: meeting.id, step: "summarize", status: .failed, error: "A社との週次定例 の要約に失敗しました")

        var settings = AppSettings()
        settings.selfName = "山田"
        settings.recordingNotice = "社外秘の会議です"
        settings.exportDirectory = "/Users/example/Documents/議事録"
        let report = try DiagnosticsReport.collect(store: store, settings: settings,
                                                   events: ["armed: A社との週次定例", "calendar: A社 定例 を検知"],
                                                   environment: .init(app: ["version": "1.0"], permissions: ["microphone": "authorized"]))

        #expect(report.events == ["armed: 〔会議 \(meeting.id)〕", "calendar: 〔会議 \(meeting.id)〕 を検知"])
        #expect(report.meetings.first?.steps.first?.error == "〔会議 \(meeting.id)〕 の要約に失敗しました")
        let recording = try #require(report.meetings.first?.recording)
        #expect(recording.tappedBundleIdentifiers == ["com.google.Chrome"])
        #expect(recording.tracks["system"]?.gapCount == 2)
        #expect(report.settings["export_directory"] == "指定あり")

        let json = String(decoding: try JSONCoding.encoder().encode(report), as: UTF8.self)
        for secret in ["A社との週次定例", "A社 定例", "売上の見込み", "山田", "社外秘", "/Users/example", "AirPods", "Google Chrome Helper"] {
            #expect(!json.contains(secret), "\(secret) が入っている")
        }
    }

    @Test("「要約しない」は要約の手段を作らない。旧い版の設定は Codex のまま")
    func summaryNone() throws {
        let decoded = try JSONCoding.decoder().decode(AppSettings.self, from: Data(#"{"summary_provider": "none"}"#.utf8))
        #expect(decoded.resolvedSummaryProvider == SummaryProvider.none)
        #expect(try SummaryProviders.make(settings: decoded) == nil)
        let legacy = try JSONCoding.decoder().decode(AppSettings.self, from: Data(#"{"target_bundle_identifiers": ["com.google.Chrome"]}"#.utf8))
        #expect(legacy.resolvedSummaryProvider == .codex)
    }

    @Test("案内を終えた日時と告知文を読み書きする。告知文が空なら既定の文面")
    func onboardingSettings() throws {
        var settings = AppSettings()
        #expect(settings.onboardingCompletedAt == nil)
        #expect(settings.resolvedRecordingNotice == AppSettings.defaultRecordingNotice)
        settings.onboardingCompletedAt = Date(timeIntervalSince1970: 1_790_000_000)
        settings.recordingNotice = "  "
        #expect(settings.resolvedRecordingNotice == AppSettings.defaultRecordingNotice)
        settings.recordingNotice = "録音しています"
        let roundTrip = try JSONCoding.decoder().decode(AppSettings.self, from: JSONCoding.encoder().encode(settings))
        #expect(roundTrip.onboardingCompletedAt == settings.onboardingCompletedAt)
        #expect(roundTrip.resolvedRecordingNotice == "録音しています")
    }
}
