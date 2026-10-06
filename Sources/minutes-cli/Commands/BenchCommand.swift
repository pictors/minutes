import Foundation
import MinutesCore

/// 録音中の書き出し処理（タイムライン整合・mono 化・AAC・16 kHz WAV）が使う CPU を、デバイスなしで測る（G7 の内訳）。
/// 実機と同じ形のチャンク（system: 48 kHz stereo 512 フレーム、mic: 48 kHz mono 2048 フレーム。2026-09-28/29 の録音ログ）を
/// 実時間より速く流し、実時間 1 秒あたりの CPU（1 コアを 100%）に直して出す。
enum BenchCommand {
    static let spec = ArgumentSpec(options: ["seconds"], flags: ["keep"])

    static func run(_ arguments: [String]) throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        let seconds = Double(parsed.value("seconds") ?? "60") ?? 60
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { if !parsed.has("keep") { try? FileManager.default.removeItem(at: directory) } }

        let rate = 48_000.0
        let t0 = HostClock.now()
        let system = TrackPipeline(name: "system", timelineStartHostTime: t0,
                                   archiveURL: directory.appendingPathComponent(RecordingSession.systemArchiveName),
                                   sttURL: directory.appendingPathComponent(RecordingSession.systemSTTName), streamLiveAudio: false)
        let mic = TrackPipeline(name: "mic", timelineStartHostTime: t0,
                                archiveURL: directory.appendingPathComponent(RecordingSession.micArchiveName),
                                sttURL: directory.appendingPathComponent(RecordingSession.micSTTName), streamLiveAudio: false)
        // 声に近い帯域の音と雑音を混ぜた 1 秒分を先に作り、切り出しの費用を計測に入れない
        let source = (0..<Int(rate)).map { i -> Float in
            let t = Double(i) / rate
            return Float(0.2 * sin(2 * .pi * 220 * t) + 0.1 * sin(2 * .pi * 1_300 * t) + 0.05 * Double.random(in: -1...1))
        }
        let systemChunks = stride(from: 0, to: source.count - 512, by: 512).map { start -> [[Float]] in
            let slice = Array(source[start..<start + 512])
            return [slice, slice]
        }
        let micChunks = stride(from: 0, to: source.count - 2048, by: 2048).map { [Array(source[$0..<$0 + 2048])] }

        let cpuStart = cpuSeconds()
        let wallStart = Date()
        let totalFrames = Int(seconds * rate)
        var systemFrames = 0
        var micFrames = 0
        var index = 0
        while systemFrames < totalFrames {
            system.enqueue(PCMChunk(channels: systemChunks[index % systemChunks.count], sampleRate: rate,
                                    hostTime: t0 + HostClock.hostTime(fromSeconds: Double(systemFrames) / rate), sampleTime: Double(systemFrames)))
            systemFrames += 512
            if micFrames + 2048 <= systemFrames {
                mic.enqueue(PCMChunk(channels: micChunks[(micFrames / 2048) % micChunks.count], sampleRate: rate,
                                     hostTime: t0 + HostClock.hostTime(fromSeconds: Double(micFrames) / rate), sampleTime: Double(micFrames)))
                micFrames += 2048
            }
            index += 1
        }
        let systemStats = system.finish()
        let micStats = mic.finish()
        let cpu = cpuSeconds() - cpuStart
        let wall = Date().timeIntervalSince(wallStart)
        if let failure = systemStats.failure ?? micStats.failure { throw failure }
        Console.out(String(format: "音声 %.0f 秒 × 2 トラック（system 48 kHz stereo / mic 48 kHz mono → AAC + 16 kHz WAV）", seconds))
        Console.out(String(format: "処理 %.1f 秒、CPU %.2f 秒 → 録音中の CPU（実時間あたり、1 コア = 100%%）: %.1f%%", wall, cpu, cpu / seconds * 100))
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
}
