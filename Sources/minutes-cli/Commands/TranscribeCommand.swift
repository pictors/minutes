import Foundation
import MinutesCore

enum TranscribeCommand {
    static let spec = ArgumentSpec(
        options: ["provider", "mic-provider", "language", "locale", "keyterms", "known-speaker", "num-speakers", "cluster-threshold", "out"],
        flags: ["no-diarize", "quiet"]
    )

    static func run(_ arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        guard let inputPath = parsed.positionals.first else { throw ArgumentError.missingPositional("dir") }
        guard let providerName = parsed.value("provider") else { throw ArgumentError.missingRequired("provider") }
        let language = parsed.value("language") ?? "ja"
        let locale = Locale(identifier: parsed.value("locale") ?? "ja-JP")
        let keyterms = parsed.list("keyterms")
        let numSpeakers = try parsed.int("num-speakers")
        let clusterThreshold = try parsed.double("cluster-threshold")
        let diarize = !parsed.has("no-diarize")
        let quiet = parsed.has("quiet")
        let knownSpeakers = try parsed.values("known-speaker").map(parseKnownSpeaker)

        let input = URL(fileURLWithPath: inputPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
            throw ArgumentError.invalidValue(option: "dir", value: inputPath, expected: "存在するパス")
        }

        var manifest: RecordingManifest?
        var systemURL: URL?
        var micURL: URL?
        let directory: URL
        if isDirectory.boolValue {
            directory = input
            if FileManager.default.fileExists(atPath: input.appendingPathComponent(RecordingManifest.fileName).path) {
                manifest = try RecordingManifest.read(from: input)
            }
            let systemName = manifest?.files["system_stt"] ?? RecordingSession.systemSTTName
            let micName = manifest?.files["mic_stt"] ?? RecordingSession.micSTTName
            let systemCandidate = input.appendingPathComponent(systemName)
            let micCandidate = input.appendingPathComponent(micName)
            if FileManager.default.fileExists(atPath: systemCandidate.path) { systemURL = systemCandidate }
            if FileManager.default.fileExists(atPath: micCandidate.path) { micURL = micCandidate }
        } else {
            directory = input.deletingLastPathComponent()
            systemURL = input
        }
        guard systemURL != nil || micURL != nil else {
            throw TranscriptionError.unsupportedAudio("\(input.path) に system_16k.wav / mic_16k.wav がありません")
        }
        // process と同じ品質検証を、プロバイダの作成・送信より前に行う。
        for (track, url) in [("system", systemURL), ("mic", micURL)] {
            let stats = manifest?.tracks[track]
            if stats != nil, url == nil { throw TranscriptionError.unsupportedAudio("\(track) の音声ファイルがありません") }
            guard let url else { continue }
            let duration = try AudioFileTools.duration(of: url)
            guard duration.isFinite, duration > 0 else {
                throw TranscriptionError.unsupportedAudio("\(track) の音声ファイルが空です")
            }
            if let stats {
                try RecordingAudioValidation.validate(stats: stats, fileDuration: duration, recordingDuration: manifest?.durationSeconds)
            }
        }

        let status: @Sendable (String) -> Void = { message in if !quiet { Console.info("[transcribe] \(message)") } }
        let provider = try makeProvider(providerName, locale: locale, numSpeakers: numSpeakers, clusterThreshold: clusterThreshold, status: status)
        let micProviderName = parsed.value("mic-provider") ?? "same"
        let micProvider: (any BatchTranscriber)?
        switch micProviderName {
        case "same": micProvider = provider
        case "none": micProvider = nil
        default: micProvider = try makeProvider(micProviderName, locale: locale, numSpeakers: nil, clusterThreshold: nil, status: status)
        }

        Console.info("provider: \(provider.id)\(provider.runsLocally ? " (local)" : " (cloud)")")
        if let systemURL { Console.info("system: \(systemURL.lastPathComponent) (\(String(format: "%.1f", (try? AudioFileTools.duration(of: systemURL)) ?? 0)) s)") }
        if let micURL { Console.info("mic: \(micURL.lastPathComponent) → \(micProvider?.id ?? "skip")") }
        let started = Date()

        let systemInput = systemURL
        let micInput = micURL
        async let systemResult: TranscriptionResult? = {
            guard let systemInput else { return nil }
            let request = TranscriptionRequest(audioURL: systemInput, language: language, diarize: diarize, keyterms: keyterms, knownSpeakers: knownSpeakers)
            return try await provider.transcribe(request)
        }()
        async let micResult: TranscriptionResult? = {
            guard let micInput, let micProvider else { return nil }
            let request = TranscriptionRequest(audioURL: micInput, language: language, diarize: false, keyterms: keyterms, knownSpeakers: [])
            return try await micProvider.transcribe(request)
        }()
        let (system, mic) = try await (systemResult, micResult)

        let merged = TrackMerger.merge(TrackMerger.Input(system: system, mic: mic))
        var meta: [String: String] = [:]
        for (key, value) in system?.providerMeta ?? [:] { meta["system.\(key)"] = value }
        for (key, value) in mic?.providerMeta ?? [:] { meta["mic.\(key)"] = value }
        if !keyterms.isEmpty { meta["keyterms"] = keyterms.joined(separator: ",") }
        meta["diarize"] = diarize ? "true" : "false"

        let meeting = TranscriptDocument.Meeting(
            id: manifest?.id ?? UUID().uuidString.lowercased(),
            title: manifest?.title ?? input.lastPathComponent,
            startedAt: manifest?.startedAt,
            durationSeconds: manifest?.durationSeconds ?? (systemURL.flatMap { try? AudioFileTools.duration(of: $0) }),
            sourceDirectory: directory.path
        )
        let document = TranscriptDocument(
            meeting: meeting,
            provider: provider.id,
            language: language,
            speakers: merged.speakers,
            segments: merged.segments,
            providerMeta: meta
        )

        let shortName = providerName.lowercased()
        let outputURL = parsed.value("out").map { URL(fileURLWithPath: $0) } ?? directory.appendingPathComponent("transcript.\(shortName).json")
        try document.write(to: outputURL)
        let textURL = outputURL.deletingPathExtension().appendingPathExtension("txt")
        try document.formattedTranscript().write(to: textURL, atomically: true, encoding: .utf8)

        Console.out("")
        Console.out("== 文字起こしサマリ (\(provider.id)) ==")
        Console.out(String(format: "elapsed: %.1f s", Date().timeIntervalSince(started)))
        Console.out("segments: \(document.segments.count)  speakers: \(document.speakers.count) (\(document.speakers.map(\.label).joined(separator: ", ")))")
        for speaker in document.speakers {
            let seconds = document.segments.filter { $0.speaker == speaker.label }.reduce(0.0) { $0 + ($1.tEnd - $1.tStart) }
            Console.out(String(format: "  %@ [%@]%@: %.0f s", speaker.label, speaker.track, speaker.providerLabel.map { " (\($0))" } ?? "", seconds))
        }
        for (key, value) in meta.sorted(by: { $0.key < $1.key }) where !key.hasSuffix("request_id") {
            Console.out("  \(key) = \(value)")
        }
        Console.out("json: \(outputURL.path)")
        Console.out("text: \(textURL.path)")
    }

    static func makeProvider(_ name: String, locale: Locale, numSpeakers: Int?, clusterThreshold: Double?, status: @escaping @Sendable (String) -> Void) throws -> any BatchTranscriber {
        switch name.lowercased() {
        case "elevenlabs", "scribe", "scribe_v2":
            guard let key = DotEnv.value(for: ElevenLabsTranscriber.apiKeyEnvName) else {
                throw TranscriptionError.missingAPIKey(provider: "ElevenLabs", envName: ElevenLabsTranscriber.apiKeyEnvName)
            }
            return ElevenLabsTranscriber(apiKey: key, numSpeakers: numSpeakers)
        case "openai", "gpt-4o-transcribe-diarize":
            guard let key = DotEnv.value(for: OpenAITranscriber.apiKeyEnvName) else {
                throw TranscriptionError.missingAPIKey(provider: "OpenAI", envName: OpenAITranscriber.apiKeyEnvName)
            }
            return OpenAITranscriber(apiKey: key)
        case "local", "apple", "speechanalyzer":
            return LocalTranscriber(locale: locale, numSpeakers: numSpeakers, clusteringThreshold: clusterThreshold, onStatus: status)
        default:
            throw ArgumentError.invalidValue(option: "provider", value: name, expected: "elevenlabs | openai | local")
        }
    }

    /// "名前=/path/to/ref.wav"
    static func parseKnownSpeaker(_ raw: String) throws -> KnownSpeaker {
        guard let eq = raw.firstIndex(of: "="), eq != raw.startIndex else {
            throw ArgumentError.invalidValue(option: "known-speaker", value: raw, expected: "名前=/path/to/ref.wav")
        }
        let name = String(raw[..<eq]).trimmingCharacters(in: .whitespaces)
        let path = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        return KnownSpeaker(name: name, referenceAudioURL: URL(fileURLWithPath: path))
    }
}
