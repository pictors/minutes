import Foundation
import MinutesCore

enum RepairRateCommand {
    static func run(_ arguments: [String]) throws {
        let parsed = try ArgumentParser.parse(arguments, spec: ArgumentSpec(options: ["out", "track", "sample-rate"], flags: []))
        guard let source = parsed.positionals.first else { throw ArgumentError.missingPositional("recording-dir") }
        guard let output = parsed.value("out") else { throw ArgumentError.missingRequired("out") }
        guard let track = parsed.value("track") else { throw ArgumentError.missingRequired("track") }
        guard let rate = try parsed.double("sample-rate") else { throw ArgumentError.missingRequired("sample-rate") }
        try RecordingRateRepair.prepareCopy(source: URL(fileURLWithPath: source), destination: URL(fileURLWithPath: output), track: track, actualSampleRate: rate)
        Console.out("音声補正コピーを作成しました: \(output)（原本・DB は変更していません）")
    }
}
