import Foundation
@testable import MinutesCore
import Synchronization
import Testing

/// 頼まれた言語を覚える文字起こし（会議の言語が後処理に届くかを見る）。
private final class LanguageRecordingTranscriber: BatchTranscriber, Sendable {
    let id = "cloud.language"
    let runsLocally = false
    let text: String
    private let requested = Mutex<[String]>([])

    init(text: String) { self.text = text }

    var languages: [String] { requested.withLock { $0 } }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        requested.withLock { $0.append(request.language) }
        return TranscriptionResult(segments: [TranscriptSegment(start: 0, end: 2, text: text, speakerLabel: request.diarize ? "speaker_0" : nil)], providerMeta: ["provider": id])
    }
}

/// 要約に渡った会議の言語と要約の言語を覚える。
private final class LanguageRecordingSummarizer: Summarizing, Sendable {
    var modelDescription: String { "fake / prompt v3" }
    private let seen = Mutex<[(MeetingLanguage?, MeetingLanguage?)]>([])

    var inputs: [(meeting: MeetingLanguage?, output: MeetingLanguage?)] { seen.withLock { $0.map { (meeting: $0.0, output: $0.1) } } }

    func summarize(_ input: SummaryInput) async throws -> MinutesSummary {
        seen.withLock { $0.append((input.meetingLanguage, input.outputLanguage)) }
        let first = input.segments.first?.id ?? 1
        return MinutesSummary(summaryMd: "Summary", decisions: [.init(text: "Decision", evidence: [first])], actionItems: [], openQuestions: [], keytermsLearned: [])
    }
}

@Suite("会議の言語（日本語・英語）")
struct MeetingLanguageTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-language-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 音声 2 トラックを置いた会議（後処理の前の状態）。
    private func meeting(in store: Store, root: URL, language: MeetingLanguage? = nil, liveText: [String] = []) throws -> MeetingRecord {
        let audio = root.appendingPathComponent("audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let samples = (0..<(16_000 * 3)).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000) * 0.3) }
        try AudioFileTools.writeWAV(samples: samples, sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
        try AudioFileTools.writeWAV(samples: samples, sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.micSTTName))
        let record = try store.createMeeting(MeetingRecord(title: "Weekly sync", startedAt: Date(), privacyMode: .cloudOk, status: .finalizing, audioDir: audio.path, language: language))
        _ = try store.appendSegments(liveText.enumerated().map { index, text in
            SegmentRecord(meetingId: record.id, source: .live, tStart: Double(index), tEnd: Double(index) + 1, text: text)
        })
        return record
    }

    @Test("言語の書き方の違いを受け付ける")
    func parseCodes() {
        #expect(MeetingLanguage(code: "ja") == .ja)
        #expect(MeetingLanguage(code: "jpn") == .ja)
        #expect(MeetingLanguage(code: "ja-JP") == .ja)
        #expect(MeetingLanguage(code: "ja_JP") == .ja)
        #expect(MeetingLanguage(code: "en") == .en)
        #expect(MeetingLanguage(code: "eng") == .en)
        #expect(MeetingLanguage(code: "EN-gb") == .en)
        #expect(MeetingLanguage(code: "zh-CN") == nil)
        #expect(MeetingLanguage(code: "") == nil)
        #expect(MeetingLanguage(code: nil) == nil)
        #expect(MeetingLanguageChoice(nil) == .auto)
        #expect(MeetingLanguageChoice(.en).language == .en)
        #expect(MeetingLanguageChoice.auto.liveLanguage == .ja)
    }

    @Test("日本語のライブ字幕の文字の種類で、英語の会議を見分ける")
    func detect() {
        // 英語の会議を ja-JP で認識した出力（ラテン文字がほとんど）
        #expect(MeetingLanguageDetector.detect([
            "OK so let's go through the release plan for next week",
            "We need to finish the onboarding changes first",
        ]) == .en)
        // 英語の言葉が多い日本語の会議（英単語は 1 語で何文字にもなる）
        #expect(MeetingLanguageDetector.detect([
            "今日は API の仕様と deploy の手順を確認します",
            "staging で onboarding の変更を見てから release しましょう",
            "それでは来週の予定を決めましょう",
        ]) == .ja)
        // 文字が足りなければ決めない
        #expect(MeetingLanguageDetector.detect(["Hello", "はい"]) == nil)
        #expect(MeetingLanguageDetector.detect([]) == nil)
    }

    @Test("ライブ字幕の言語を録音中に切り替える値は、どのスレッドからも読める")
    func liveControl() {
        let control = LiveLocaleControl(locale: MeetingLanguage.ja.locale)
        #expect(control.locale.identifier == "ja-JP")
        control.set(MeetingLanguage.en.locale)
        #expect(control.locale.identifier == "en-US")
    }

    @Test("設定: ライブ字幕を英語にしていた旧い設定は英語の会議として読み、新しい値は往復する")
    func settings() throws {
        let decoder = JSONCoding.decoder()
        let legacyEnglish = try decoder.decode(AppSettings.self, from: Data(#"{"live_locale": "en-US", "include_mic": false}"#.utf8))
        #expect(legacyEnglish.meetingLanguage == .en)
        #expect(legacyEnglish.includeMic == false)
        let legacyJapanese = try decoder.decode(AppSettings.self, from: Data(#"{"live_locale": "ja-JP"}"#.utf8))
        #expect(legacyJapanese.meetingLanguage == .auto)
        #expect(legacyJapanese.englishSummaryLanguage == .en)
        // 未知の値でほかの設定を既定に戻さない
        let unknown = try decoder.decode(AppSettings.self, from: Data(#"{"meeting_language": "fr", "english_summary_language": "de", "silence_timeout_seconds": 90}"#.utf8))
        #expect(unknown.meetingLanguage == .auto)
        #expect(unknown.englishSummaryLanguage == .en)
        #expect(unknown.silenceTimeoutSeconds == 90)

        var settings = AppSettings()
        settings.meetingLanguage = .en
        settings.englishSummaryLanguage = .ja
        let decoded = try decoder.decode(AppSettings.self, from: JSONCoding.encoder().encode(settings))
        #expect(decoded.meetingLanguage == .en)
        #expect(decoded.englishSummaryLanguage == .ja)
    }

    @Test("自動: 英語の会議と判定したら英語で文字起こしし、要約も英語にする（設定で日本語にもできる）")
    func autoDetectEnglish() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for summaryLanguage in [MeetingLanguage.en, .ja] {
            let store = try Store.inMemory()
            let record = try meeting(in: store, root: root, liveText: [
                "OK so let's go through the release plan for next week",
                "We need to finish the onboarding changes first",
            ])
            let transcriber = LanguageRecordingTranscriber(text: "Let's ship it next Tuesday")
            let summarizer = LanguageRecordingSummarizer()
            let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(
                cloud: transcriber, local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []), summarizer: summarizer,
                exportDirectory: root.appendingPathComponent("export-\(summaryLanguage.rawValue)"), englishSummaryLanguage: summaryLanguage
            ))
            let outcome = try await pipeline.run(meetingId: record.id)

            #expect(transcriber.languages == ["en", "en"])
            let saved = try #require(try store.meeting(id: record.id))
            #expect(saved.language == "en")
            #expect(saved.languageDetected)
            #expect(saved.summaryOutputLanguage == summaryLanguage)
            #expect(summarizer.inputs.first?.meeting == .en)
            #expect(summarizer.inputs.first?.output == (summaryLanguage == .ja ? nil : .en))
            #expect(try store.latestRun(meetingId: record.id, step: "transcribe_final")?.provider?.contains("language: en (detected)") == true)

            // 書き出し: 本文の言語と、要約の言語に合わせた見出し
            let folder = URL(fileURLWithPath: try #require(outcome.exportPath))
            let markdown = try String(contentsOf: folder.appendingPathComponent("meeting.md"), encoding: .utf8)
            #expect(markdown.contains("language: en"))
            #expect(markdown.contains(summaryLanguage == .en ? "## Summary" : "## 要約"))
            #expect(markdown.contains(summaryLanguage == .en ? "## Transcript" : "## 全文（話者付き）"))
            let document = try JSONCoding.decoder().decode(TranscriptDocument.self, from: Data(contentsOf: folder.appendingPathComponent("transcript.json")))
            #expect(document.language == "en")

            // もう一度掛けても、決まった言語のまま完了済みのステップを飛ばす
            let again = try await pipeline.run(meetingId: record.id)
            #expect(again.executed == [.notify])
        }
    }

    @Test("自動: 日本語の会議・字幕がない会議は日本語のまま、入力のハッシュも言語を持つ前と同じ")
    func autoJapanese() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let japanese = try meeting(in: store, root: root, liveText: ["それでは今週の進み具合から確認していきましょう。デザインの見直しは昨日終わりました。"])
        let silent = try meeting(in: store, root: root)
        let transcriber = LanguageRecordingTranscriber(text: "リリース日は 10 月 21 日にします")
        let summarizer = LanguageRecordingSummarizer()
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(
            cloud: transcriber, local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []), summarizer: summarizer,
            exportDirectory: root.appendingPathComponent("export")
        ))
        _ = try await pipeline.run(meetingId: japanese.id)
        _ = try await pipeline.run(meetingId: silent.id)
        #expect(transcriber.languages == ["ja", "ja", "ja", "ja"])
        for id in [japanese.id, silent.id] {
            let saved = try #require(try store.meeting(id: id))
            #expect(saved.meetingLanguage == .ja)
            #expect(saved.summaryOutputLanguage == .ja)
            // 日本語の会議の要約の入力は、言語を持つ前と同じ形（言語の欄を書かない）
            let input = try store.summaryInput(meetingId: id)
            #expect(input.meetingLanguage == nil && input.outputLanguage == nil)
            let json = String(decoding: try JSONCoding.encoder().encode(input), as: UTF8.self)
            #expect(!json.contains("language"))
        }
        #expect(summarizer.inputs.allSatisfy { $0.meeting == nil && $0.output == nil })
    }

    @Test("録音中に選んだ言語は判定せずに使う。会議の言語を変えると文字起こしからやり直し、本文の編集は履歴に残して外す")
    func chosenLanguageAndRetranscription() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        // 字幕は日本語でも、選んだ言語（英語）を優先する
        let record = try meeting(in: store, root: root, language: .en, liveText: ["それでは今週の進み具合から確認していきましょう。デザインの見直しは昨日終わりました。"])
        let transcriber = LanguageRecordingTranscriber(text: "Let's ship it next Tuesday")
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(
            cloud: transcriber, local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []), summarizer: LanguageRecordingSummarizer(),
            exportDirectory: root.appendingPathComponent("export")
        ))
        _ = try await pipeline.run(meetingId: record.id)
        #expect(transcriber.languages == ["en", "en"])
        #expect(try store.meeting(id: record.id)?.languageDetected == false)

        // 本文を編集してから、日本語に変える
        let edited = try #require(try store.segments(meetingId: record.id, source: .final).first)
        try store.updateSegmentText(id: try #require(edited.id), text: "Edited by hand")
        #expect(try store.hasTranscriptEdits(meetingId: record.id))
        try store.prepareRetranscription(meetingId: record.id)
        try store.setMeetingLanguage(id: record.id, language: .ja, detected: false)
        #expect(try store.hasTranscriptEdits(meetingId: record.id) == false)
        #expect(try store.meeting(id: record.id)?.summaryLanguage == nil)

        let rerun = try await pipeline.run(meetingId: record.id)
        #expect(rerun.executed.contains(.transcribeFinal))
        #expect(transcriber.languages.suffix(2) == ["ja", "ja"])
        let saved = try #require(try store.meeting(id: record.id))
        #expect(saved.meetingLanguage == .ja && saved.summaryOutputLanguage == .ja)
    }

    @Test("要約の言語だけを変えると、要約を作り直す（本文はそのまま）")
    func summaryLanguageOnly() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let record = try meeting(in: store, root: root, language: .en)
        let transcriber = LanguageRecordingTranscriber(text: "Let's ship it next Tuesday")
        let summarizer = LanguageRecordingSummarizer()
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(
            cloud: transcriber, local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []), summarizer: summarizer,
            exportDirectory: root.appendingPathComponent("export")
        ))
        _ = try await pipeline.run(meetingId: record.id)
        #expect(summarizer.inputs.last?.output == .en)
        try store.setSummaryLanguage(id: record.id, language: .ja)
        try await pipeline.regenerateSummary(meetingId: record.id)
        #expect(summarizer.inputs.last?.meeting == .en)
        #expect(summarizer.inputs.last?.output == nil)
        #expect(transcriber.languages.count == 2)
    }
}

@Suite("要約の指示文の言語")
struct SummaryPromptLanguageTests {
    @Test("日本語の会議は v2 と同じ指示、英語の要約は本文の欄まで英語と明示する")
    func systemMessage() throws {
        let prompt = try SummaryPrompt.loadBundled()
        #expect(prompt.version == 3)
        let japanese = SummaryInput(meetingTitle: "定例", startedAt: nil, attendees: [], segments: [])
        let jaSystem = prompt.systemMessage(for: japanese)
        #expect(jaSystem.contains("あなたは日本語のビジネス会議の議事録担当です。"))
        #expect(jaSystem.contains("- 出力はすべて日本語。"))
        #expect(!jaSystem.contains("{{"))

        let english = SummaryInput(meetingTitle: "Weekly", startedAt: nil, attendees: [], segments: [], meetingLanguage: .en, outputLanguage: .en)
        let enSystem = prompt.systemMessage(for: english)
        #expect(enSystem.contains("あなたは英語のビジネス会議の議事録担当です。"))
        #expect(enSystem.contains("出力はすべて英語（summary_md・decisions・action_items・open_questions の文章を英語で書く）。"))

        // 英語の会議を日本語でまとめる
        let translated = SummaryInput(meetingTitle: "Weekly", startedAt: nil, attendees: [], segments: [], meetingLanguage: .en)
        let mixed = prompt.systemMessage(for: translated)
        #expect(mixed.contains("あなたは英語のビジネス会議") && mixed.contains("- 出力はすべて日本語。"))
    }
}

/// 音声を流さない録音（会議の言語の切り替えだけを見る）。
private final class SilentRecording: MeetingRecording, @unchecked Sendable {
    let options: RecordingOptions
    let startedAt: Date? = Date()
    let tappedProcesses: [AudioProcessInfo] = []
    let systemChunks: AsyncStream<AudioChunk>? = nil
    let micChunks: AsyncStream<AudioChunk>? = nil
    var onEvent: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (CaptureFailure) -> Void)?
    init(options: RecordingOptions) { self.options = options }
    func start() async throws {}
    func finishRecording() throws {}
    func snapshot() -> RecordingSession.Snapshot {
        .init(elapsedSeconds: 1, system: nil, mic: nil, cpuPercent: 0, residentBytes: 0, tappedProcessCount: 0)
    }
}

@Suite("録音中の言語の切り替え")
struct LiveLanguageSwitchTests {
    @Test("選んだ言語で会議を作り、録音中に切り替えると会議の言語も変わる（自動判定はしない）")
    func switchWhileRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-live-language-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try Store.inMemory()
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(cloud: nil, local: FakeTranscriber(id: "local", runsLocally: true, segments: []), summarizer: nil, exportDirectory: root))
        var config = SessionConfiguration(targetBundleIdentifiers: [], audioRootDirectory: root)
        config.liveTranscription = false
        let controller = MeetingSessionController(store: store, pipeline: pipeline, configuration: config, makeRecording: { SilentRecording(options: $0) })

        // 自動: 会議の言語は決めず、ライブ字幕は日本語
        try await controller.start(PendingMeetingInfo(title: "auto"))
        let autoId = try #require(await controller.currentMeeting?.id)
        #expect(try store.meeting(id: autoId)?.language == nil)
        #expect(await controller.snapshot().liveLanguage == .ja)

        try await controller.setLiveLanguage(.en)
        #expect(await controller.snapshot().liveLanguage == .en)
        let switched = try #require(try store.meeting(id: autoId))
        #expect(switched.language == "en")
        #expect(switched.languageDetected == false)
        #expect(await controller.currentMeeting?.language == "en")
        await controller.stop()

        // 録音していなければ切り替えられない
        await #expect(throws: AudioCaptureError.self) { try await controller.setLiveLanguage(.ja) }

        // 選んだ言語で始めた会議
        try await controller.start(PendingMeetingInfo(title: "english", language: .en))
        let englishId = try #require(await controller.currentMeeting?.id)
        #expect(try store.meeting(id: englishId)?.language == "en")
        #expect(await controller.snapshot().liveLanguage == .en)
        await controller.stop()
    }
}

/// 実際の SpeechAnalyzer で、録音中の言語の切り替え（認識器を閉じて開き直す）を確かめる任意テスト。
/// `MINUTES_SPEECH_LIVE=1 swift test --filter LiveLocaleRestartTests`。fixtures/sample_meeting（make-fixtures.py の日本語の TTS）を使う。
/// 新しいモデルを落とさないよう、入っている日本語のモデルのまま、ロケールの書き方を変えて（ja-JP → ja_JP）開き直させる。
@Suite("ライブ字幕の認識器の開き直し（任意）")
struct LiveLocaleRestartTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINUTES_SPEECH_LIVE"] == "1"))
    func restartMidStream() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../fixtures/sample_meeting/system_16k.wav").standardizedFileURL
        let samples = try AudioFileTools.loadMono16k(url)
        let rate = AudioFileTools.sttSampleRate
        let total = Double(samples.count) / rate
        let switchAt = total / 2
        let control = LiveLocaleControl(locale: Locale(identifier: "ja-JP"))
        let preparations = Mutex<[LivePreparation]>([])
        let transcriber = SpeechAnalyzerLiveTranscriber(reportVolatile: false, onPreparation: { preparation in preparations.withLock { $0.append(preparation) } })
        let (audio, input) = AsyncStream<AudioChunk>.makeStream()
        let results = transcriber.start(audio: audio, control: control)
        let feeder = Task {
            // 0.1 秒ずつ、実時間の 20 倍で流す。半分を過ぎたところで切り替える
            let step = Int(rate / 10)
            var offset = 0
            while offset < samples.count {
                let end = min(samples.count, offset + step)
                let start = Double(offset) / rate
                if start >= switchAt, control.locale.identifier == "ja-JP" { control.set(Locale(identifier: "ja_JP")) }
                input.yield(AudioChunk(samples: Array(samples[offset..<end]), sampleRate: rate, startTime: start))
                offset = end
                try? await Task.sleep(for: .milliseconds(5))
            }
            input.finish()
        }
        var finals: [LiveSegment] = []
        for try await segment in results where segment.isFinal && !segment.text.isEmpty { finals.append(segment) }
        await feeder.value

        // 開き直す前と後の両方で字幕が確定し、時刻は録音のタイムラインのまま進む
        #expect(finals.contains { $0.end <= switchAt + 1 })
        #expect(finals.contains { $0.start >= switchAt - 1 })
        #expect(zip(finals, finals.dropFirst()).allSatisfy { $1.start >= $0.start - 0.5 })
        #expect(finals.last.map { $0.end <= total + 1 } == true)
        // 認識器を 2 回用意した（開き直した）
        #expect(preparations.withLock { $0.filter { if case .ready = $0 { true } else { false } }.count } == 2)
    }
}

@Suite("完了した会議のやり直しの依頼")
struct ReprocessRequestTests {
    @Test("完了した会議は、やり直しと明示したときだけ後処理を依頼できる")
    func reprocessDone() throws {
        let store = try Store.inMemory()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-reprocess-" + UUID().uuidString)
        let meeting = try store.createMeeting(MeetingRecord(title: "done", startedAt: Date(), privacyMode: .cloudOk, status: .done, audioDir: directory.path))
        #expect(throws: StoreError.self) { try store.requestPostProcessing(meetingId: meeting.id) }
        try store.requestPostProcessing(meetingId: meeting.id, reprocess: true)
        #expect(try store.postProcessingJobs().map(\.meetingId) == [meeting.id])
        #expect(try store.meeting(id: meeting.id)?.meetingStatus == .finalizing)
    }
}

extension ReprocessRequestTests {
    @Test("会議の言語を変えて依頼すると、キューが新しい言語で文字起こしし直し、会議を完了に戻す")
    func reprocessThroughQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-reprocess-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let samples = (0..<(16_000 * 3)).map { Float(sin(Double($0) * 2 * .pi * 220 / 16_000) * 0.3) }
        try AudioFileTools.writeWAV(samples: samples, sampleRate: 16_000, to: audio.appendingPathComponent(RecordingSession.systemSTTName))
        let store = try Store.inMemory()
        let meeting = try store.createMeeting(MeetingRecord(title: "weekly", startedAt: Date(), privacyMode: .cloudOk, status: .finalizing, audioDir: audio.path))
        let transcriber = LanguageRecordingTranscriber(text: "テストです")
        let pipeline = PostProcessPipeline(store: store, providers: PipelineProviders(
            cloud: transcriber, local: FakeTranscriber(id: "local.fake", runsLocally: true, segments: []), summarizer: nil,
            exportDirectory: root.appendingPathComponent("export")
        ))
        _ = try await pipeline.run(meetingId: meeting.id)
        #expect(transcriber.languages == ["ja"])
        #expect(try store.meeting(id: meeting.id)?.meetingStatus == .done)

        try store.prepareRetranscription(meetingId: meeting.id)
        try store.setMeetingLanguage(id: meeting.id, language: .en, detected: false)
        try store.requestPostProcessing(meetingId: meeting.id, reprocess: true)
        let queue = PostProcessingQueue(store: store, pipeline: pipeline)
        await queue.start()
        await queue.waitUntilIdle()
        #expect(transcriber.languages == ["ja", "en"])
        let saved = try #require(try store.meeting(id: meeting.id))
        #expect(saved.meetingStatus == .done)
        #expect(saved.meetingLanguage == .en && saved.summaryOutputLanguage == .en)
        #expect(try store.postProcessingJobs().isEmpty)
    }
}
