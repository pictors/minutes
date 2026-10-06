import Foundation
import MinutesCore

enum LiveCommand {
    static let spec = ArgumentSpec(
        options: ["app", "out", "locale", "duration", "clock-device", "file"],
        flags: ["mic", "no-volatile", "all-system-audio", "fast", "fast-results"]
    )

    struct LatencyRecord: Codable, Sendable {
        var track: String
        var isFinal: Bool
        var start: Double
        var end: Double
        var receivedAtTimeline: Double
        var latencySeconds: Double
        var chars: Int
    }

    final class LatencyLog: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var records: [LatencyRecord] = []
        private let writer: JSONLinesWriter?

        init(writer: JSONLinesWriter?) { self.writer = writer }

        func add(_ record: LatencyRecord) {
            lock.withLock { records.append(record) }
            writer?.append(record)
        }

        /// volatile = 表示中の途中結果が音声からどれだけ遅れているか（G2 の指標）。final = 確定までの遅延。
        func summary(track: String) -> String {
            let (finals, volatiles) = lock.withLock {
                (records.filter { $0.track == track && $0.isFinal }.map(\.latencySeconds),
                 records.filter { $0.track == track && !$0.isFinal }.map(\.latencySeconds))
            }
            guard !finals.isEmpty || !volatiles.isEmpty else { return "\(track): 結果なし" }
            func stats(_ values: [Double]) -> String {
                guard !values.isEmpty else { return "n/a" }
                return String(format: "median=%.2fs p90=%.2fs max=%.2fs (n=%d)",
                              Statistics.percentile(values, 0.5) ?? 0, Statistics.percentile(values, 0.9) ?? 0, values.max() ?? 0, values.count)
            }
            return "\(track): volatile 追従遅延 \(stats(volatiles)) [G2 目標 中央値 < 2 s] | final 確定遅延 \(stats(finals))"
        }
    }

    static func run(_ arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        if let file = parsed.value("file") {
            try await runFromFile(
                URL(fileURLWithPath: file),
                locale: Locale(identifier: parsed.value("locale") ?? "ja-JP"),
                reportVolatile: !parsed.has("no-volatile"),
                fastResults: parsed.has("fast-results"),
                realtime: !parsed.has("fast")
            )
            return
        }
        let apps = parsed.list("app")
        let allSystemAudio = parsed.has("all-system-audio")
        if apps.isEmpty, !allSystemAudio { throw ArgumentError.missingRequired("app") }
        let locale = Locale(identifier: parsed.value("locale") ?? "ja-JP")
        let duration = try parsed.double("duration")
        let transcribeMic = parsed.has("mic")

        let outDirectory: URL
        let writeFiles: Bool
        if let out = parsed.value("out") {
            outDirectory = URL(fileURLWithPath: out)
            writeFiles = true
        } else {
            outDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-live-\(JSONCoding.folderTimestamp(Date()))")
            writeFiles = false
        }

        var options = RecordingOptions(outputDirectory: outDirectory)
        options.targetBundleIdentifiers = apps
        options.allSystemAudio = allSystemAudio
        options.includeMic = transcribeMic
        options.writeAudioFiles = writeFiles
        options.clockDeviceUID = parsed.value("clock-device")

        // モデルを先に確認しておく（初回はダウンロードが入る）
        let status = try await SpeechAssets.status(for: locale)
        Console.info("SpeechTranscriber \(locale.identifier): \(status)")

        let session = RecordingSession(options: options)
        session.onEvent = { Console.info("[event] \($0)") }
        let run = RecordingRun(recording: session)
        let signals = RecordingSignals(request: run.stopRequest)
        defer { try? run.close(); signals.close() }
        try await run.start()
        signals.startTimeout(duration)
        let t0 = HostClock.seconds(fromHostTime: session.timelineStartHostTime)
        for process in session.tappedProcesses {
            Console.info("録音中: \(process.name ?? "?") (pid \(process.pid), \(process.bundleID ?? "-"))")
        }
        if writeFiles { Console.info("音声とログの保存先: \(outDirectory.path)") }

        let writer = writeFiles ? try JSONLinesWriter(url: outDirectory.appendingPathComponent("live_log.jsonl")) : nil
        defer { writer?.close() }
        let log = LatencyLog(writer: writer)
        let reportVolatile = !parsed.has("no-volatile")
        let fastResults = parsed.has("fast-results")

        func consume(track: String, prefix: String, chunks: AsyncStream<AudioChunk>) -> Task<Void, Never> {
            Task {
                let transcriber = SpeechAnalyzerLiveTranscriber(reportVolatile: reportVolatile, fastResults: fastResults) { Console.info("[\(track)] \($0)") }
                do {
                    for try await segment in transcriber.start(audio: chunks, locale: locale) {
                        let latency = segment.receivedAt - (t0 + segment.end)
                        log.add(LatencyRecord(track: track, isFinal: segment.isFinal, start: segment.start, end: segment.end, receivedAtTimeline: segment.receivedAt - t0, latencySeconds: latency, chars: segment.text.count))
                        if segment.isFinal {
                            Console.clearLine()
                            Console.out(String(format: "[%@–%@] %@%@   (%+.2fs)", TimeFormatting.mmss(segment.start), TimeFormatting.mmss(segment.end), prefix, segment.text, latency))
                        } else {
                            Console.overwriteLine("… \(prefix)\(segment.text)")
                        }
                    }
                } catch {
                    Console.error("[\(track)] ライブ字幕エラー: \(error.localizedDescription)")
                }
            }
        }

        var tasks: [Task<Void, Never>] = []
        if let systemChunks = session.systemChunks {
            tasks.append(consume(track: "system", prefix: "", chunks: systemChunks))
        }
        if transcribeMic, let micChunks = session.micChunks {
            tasks.append(consume(track: "mic", prefix: "me: ", chunks: micChunks))
        }
        Console.info("ライブ字幕を開始しました。Ctrl-C で停止します。")

        let reason = await run.stopRequest.wait()
        Console.clearLine()
        Console.info(reason == .timeout ? "指定時間に達したので停止します" : "停止中（確定待ち）…")
        let result = Result { try run.finish(after: reason) }
        await TaskDrain.wait(tasks, timeout: .seconds(15))
        try result.get()
        let manifest = try RecordingManifest.read(from: outDirectory)

        Console.out("")
        Console.out("== ライブ字幕サマリ ==")
        Console.out(String(format: "duration: %.1f s", manifest.durationSeconds ?? 0))
        Console.out(log.summary(track: "system"))
        if transcribeMic { Console.out(log.summary(track: "mic")) }
        if let usage = manifest.resourceUsage {
            Console.out(String(format: "cpu: avg %.1f%% max %.1f%%", usage.cpuPercentAvg, usage.cpuPercentMax))
        }
        if writeFiles {
            Console.out("latency log: \(outDirectory.appendingPathComponent("live_log.jsonl").path)")
        } else {
            try? FileManager.default.removeItem(at: outDirectory)
        }
    }

    /// 録音せず、音声ファイルを（実時間ペースで）流して live 経路を評価する。
    static func runFromFile(_ url: URL, locale: Locale, reportVolatile: Bool, fastResults: Bool, realtime: Bool) async throws {
        let status = try await SpeechAssets.status(for: locale)
        Console.info("SpeechTranscriber \(locale.identifier): \(status)")
        let source = try FileAudioSource.stream(url: url, realtime: realtime)
        Console.info(String(format: "file: %@ (%.1f s, %@)", url.lastPathComponent, source.durationSeconds, realtime ? "realtime" : "fast"))
        let log = LatencyLog(writer: nil)
        let transcriber = SpeechAnalyzerLiveTranscriber(reportVolatile: reportVolatile, fastResults: fastResults) { Console.info("[file] \($0)") }
        let t0 = HostClock.nowSeconds()
        let started = Date()
        var finals = 0
        for try await segment in transcriber.start(audio: source.stream, locale: locale) {
            let latency = segment.receivedAt - (t0 + segment.end)
            log.add(LatencyRecord(track: "file", isFinal: segment.isFinal, start: segment.start, end: segment.end, receivedAtTimeline: segment.receivedAt - t0, latencySeconds: latency, chars: segment.text.count))
            if segment.isFinal {
                finals += 1
                Console.clearLine()
                Console.out(String(format: "[%@–%@] %@   (%+.2fs)", TimeFormatting.mmss(segment.start), TimeFormatting.mmss(segment.end), segment.text, latency))
            } else {
                Console.overwriteLine("… \(segment.text)")
            }
        }
        Console.clearLine()
        let elapsed = Date().timeIntervalSince(started)
        Console.out("")
        Console.out("== ライブ字幕サマリ（ファイル入力） ==")
        Console.out(String(format: "audio %.1f s, wall %.1f s (%.2fx realtime)", source.durationSeconds, elapsed, source.durationSeconds / max(elapsed, 0.001)))
        Console.out(realtime ? log.summary(track: "file") : "finals=\(finals)（--fast では遅延は意味を持たない）")
    }
}
