import Foundation
import MinutesCore
import Speech

enum AssetsCommand {
    static let spec = ArgumentSpec(options: ["locale"], flags: ["install"])

    static func run(_ arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        let locale = Locale(identifier: parsed.value("locale") ?? "ja-JP")
        Console.out("SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        let resolved = try await SpeechAssets.resolveLocale(locale)
        Console.out("locale: \(locale.identifier) → \(resolved.identifier)")
        let installed = await SpeechAssets.installedLocales()
        Console.out("installed locales: \(installed.map(\.identifier).sorted().joined(separator: ", "))")
        let status = try await SpeechAssets.status(for: locale)
        Console.out("status: \(status)")
        if parsed.has("install"), status != .installed {
            let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
            Console.info("モデルをダウンロードします…")
            try await SpeechAssets.ensureInstalled(for: [transcriber], locale: resolved) { fraction in
                Console.overwriteLine(String(format: "download %.0f%%", fraction * 100))
            }
            Console.clearLine()
            Console.out("status: \(try await SpeechAssets.status(for: locale))")
        }
        let transcriber = SpeechTranscriber(locale: resolved, preset: .transcription)
        if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) {
            Console.out("best audio format: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, \(format.commonFormat.rawValue)")
        }
    }
}
