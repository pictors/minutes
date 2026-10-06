import Foundation
import MinutesCore

enum RecordCommand {
    static let spec = ArgumentSpec(
        options: ["app", "out", "duration", "log-interval", "clock-device", "mic-device", "bitrate", "title"],
        flags: ["no-mic", "no-system", "all-system-audio", "tap-autostart", "no-follow"]
    )

    static func run(_ arguments: [String]) async throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        let apps = parsed.list("app")
        let allSystemAudio = parsed.has("all-system-audio")
        let includeSystem = !parsed.has("no-system")
        if includeSystem, apps.isEmpty, !allSystemAudio {
            throw ArgumentError.missingRequired("app")
        }
        let outDirectory = parsed.value("out").map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "recordings").appendingPathComponent(JSONCoding.folderTimestamp(Date()))

        var options = RecordingOptions(outputDirectory: outDirectory)
        options.streamLiveAudio = false
        options.targetBundleIdentifiers = apps
        options.includeSystem = includeSystem
        options.includeMic = !parsed.has("no-mic")
        options.allSystemAudio = allSystemAudio
        options.tapAutoStart = parsed.has("tap-autostart")
        options.clockDeviceUID = parsed.value("clock-device")
        options.micDeviceUID = parsed.value("mic-device")
        options.followNewProcesses = !parsed.has("no-follow")
        options.title = parsed.value("title")
        if let bitrate = try parsed.int("bitrate") { options.aacBitrate = bitrate }
        let duration = try parsed.double("duration")
        let interval = try parsed.double("log-interval") ?? 10

        let session = RecordingSession(options: options)
        session.onEvent = { Console.info("[event] \($0)") }
        let run = RecordingRun(recording: session)
        let signals = RecordingSignals(request: run.stopRequest)
        defer { try? run.close(); signals.close() }

        Console.info("出力先: \(outDirectory.path)")
        if includeSystem {
            Console.info(allSystemAudio ? "system track: 全システム音声" : "system track: \(apps.joined(separator: ", "))")
        }
        Console.info("mic track: \(options.includeMic ? (options.micDeviceUID.map { "uid " + $0 } ?? MicCapture.defaultInputDeviceName() ?? "既定の入力") : "なし")")
        try await run.start()
        signals.startTimeout(duration)

        // 誤録音防止のため、録音対象を明示する（SPEC §6.2）
        if !session.tappedProcesses.isEmpty {
            Console.info("録音中のプロセス:")
            for process in session.tappedProcesses {
                Console.info("  - \(process.name ?? "?") (pid \(process.pid), \(process.bundleID ?? "-"))\(process.isRunningOutput ? " [出力中]" : "")")
            }
        }
        if let clock = session.clockDeviceName { Console.info("aggregate clock: \(clock)") }
        if let stream = session.tapStreamDescription { Console.info("tap stream: \(stream)") }
        Console.info("録音開始 \(JSONCoding.iso8601Local(session.startedAt ?? Date()))。Ctrl-C で停止します。")

        let logWriter = try JSONLinesWriter(url: outDirectory.appendingPathComponent("record_log.jsonl"))
        defer { logWriter.close() }
        let statsTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                let snapshot = session.snapshot()
                Console.out(snapshot.formatted())
                logWriter.append(snapshot)
            }
        }

        let reason = await run.stopRequest.wait()
        statsTask.cancel()
        await statsTask.value
        Console.info(reason == .timeout ? "指定時間に達したので停止します" : "停止中…")
        let final = session.snapshot()
        Console.out(final.formatted())
        logWriter.append(final)
        try run.finish(after: reason)
        let manifest = try RecordingManifest.read(from: outDirectory)
        printSummary(manifest, directory: outDirectory)
    }

    static func printSummary(_ manifest: RecordingManifest, directory: URL) {
        Console.out("")
        Console.out("== 録音サマリ ==")
        Console.out("id: \(manifest.id)")
        Console.out(String(format: "duration: %.1f s", manifest.durationSeconds ?? 0))
        for (name, track) in manifest.tracks.sorted(by: { $0.key < $1.key }) {
            let drift = track.driftSeconds.map { String(format: "%+.1f ms", $0 * 1000) } ?? "n/a"
            Console.out(String(
                format: "%@: src=%dHz/%dch received=%.1fs written=%.1fs first_offset=%.1fms gaps=%d(%.3fs) overlaps=%d formatChanges=%d active=%.0fs drift=%@",
                name, Int(track.sourceSampleRate), track.sourceChannels, track.receivedSeconds, track.writtenSeconds,
                (track.firstChunkOffsetSeconds ?? 0) * 1000, track.gapCount, track.gapSeconds, track.overlapCount,
                track.formatChanges, track.activeSeconds, drift
            ))
        }
        if let usage = manifest.resourceUsage {
            Console.out(String(format: "cpu: avg %.1f%% max %.1f%% (G7 目標 < 20%%), rss max %d MB", usage.cpuPercentAvg, usage.cpuPercentMax, Int(usage.rssMaxBytes / 1_048_576)))
        }
        for (role, file) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(file)
            let size = (try? AudioFileTools.fileSize(url)) ?? 0
            Console.out("\(role): \(url.path) (\(Console.formatBytes(size)))")
        }
        Console.out("manifest: \(directory.appendingPathComponent(RecordingManifest.fileName).path)")
        if manifest.tracks.values.contains(where: { $0.gapCount > 0 }) {
            Console.out("⚠️ dropout（欠落）が検出されました。record_log.jsonl と events を確認してください。")
        } else {
            Console.out("✅ dropout なし")
        }
    }
}
