import Foundation
import MinutesCore

enum EvalCommand {
    static let spec = ArgumentSpec(
        options: ["track"],
        flags: ["strip-speaker-prefix", "strip-timestamps", "json"]
    )

    struct Report: Codable {
        var transcript: String
        var reference: String
        var provider: String
        var track: String
        var cer: Double
        var editDistance: Int
        var referenceChars: Int
        var hypothesisChars: Int
        var segments: Int
        var speakers: Int
        var speakerLabels: [String]
        var providerMeta: [String: String]
    }

    static func run(_ arguments: [String]) throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        guard parsed.positionals.count >= 2 else {
            throw ArgumentError.missingPositional(parsed.positionals.isEmpty ? "transcript.json" : "reference.txt")
        }
        let transcriptURL = URL(fileURLWithPath: parsed.positionals[0])
        let referenceURL = URL(fileURLWithPath: parsed.positionals[1])
        let track = parsed.value("track") ?? "all"
        guard ["all", "system", "mic"].contains(track) else {
            throw ArgumentError.invalidValue(option: "track", value: track, expected: "all | system | mic")
        }

        let document = try TranscriptDocument.read(from: transcriptURL)
        var reference = try String(contentsOf: referenceURL, encoding: .utf8)
        if parsed.has("strip-timestamps") { reference = TextNormalizer.stripTimestamps(reference) }
        if parsed.has("strip-speaker-prefix") { reference = TextNormalizer.stripSpeakerPrefixes(reference) }

        let segments = document.segments
            .filter { track == "all" || $0.track == track }
            .sorted { $0.tStart < $1.tStart }
        let hypothesis = segments.map(\.text).joined(separator: "\n")
        let result = CER.compute(reference: reference, hypothesis: hypothesis)
        let labels = Array(Set(segments.compactMap(\.speaker))).sorted()

        let report = Report(
            transcript: transcriptURL.path,
            reference: referenceURL.path,
            provider: document.provider,
            track: track,
            cer: result.cer,
            editDistance: result.editDistance,
            referenceChars: result.referenceLength,
            hypothesisChars: result.hypothesisLength,
            segments: segments.count,
            speakers: labels.count,
            speakerLabels: labels,
            providerMeta: document.providerMeta
        )

        if parsed.has("json") {
            let data = try JSONCoding.encoder().encode(report)
            Console.out(String(decoding: data, as: UTF8.self))
        } else {
            Console.out("provider: \(report.provider)  track: \(report.track)")
            Console.out(String(format: "CER: %.2f%%  (edit distance %d / reference %d chars, hypothesis %d chars)", report.cer * 100, report.editDistance, report.referenceChars, report.hypothesisChars))
            Console.out("segments: \(report.segments)  speakers: \(report.speakers) [\(labels.joined(separator: ", "))]")
        }
    }
}
