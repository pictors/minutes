import Foundation

/// デバイスのサンプル時計とホスト時計を独立に比較する。
/// フレーム欠落・時刻リセット・形式変更の区間は速度推定に使わない。
struct AudioClockMonitor {
    private var previous: (host: Double, sample: Double, frames: Int, rate: Double)?
    private var windowHost = 0.0
    private var windowFrames = 0.0
    private var mismatchedWindows = 0
    private(set) var observedSampleRate: Double?

    mutating func observe(_ chunk: PCMChunk) -> String? {
        guard chunk.hostTime != 0, chunk.sampleTime.isFinite else {
            reset()
            return nil
        }
        let host = HostClock.seconds(fromHostTime: chunk.hostTime)
        defer { previous = (host, chunk.sampleTime, chunk.frameCount, chunk.sampleRate) }
        guard let last = previous, last.rate == chunk.sampleRate else {
            reset()
            return nil
        }
        let elapsed = host - last.host
        let frames = chunk.sampleTime - last.sample
        guard elapsed > 0, elapsed < 0.5, abs(frames - Double(last.frames)) < 0.5 else {
            reset()
            return nil
        }
        windowHost += elapsed
        windowFrames += frames
        guard windowHost >= 1 else { return nil }
        let measured = windowFrames / windowHost
        observedSampleRate = measured
        windowHost = 0
        windowFrames = 0
        if abs(measured / chunk.sampleRate - 1) > 0.02 {
            mismatchedWindows += 1
        } else {
            mismatchedWindows = 0
        }
        guard mismatchedWindows >= 2 else { return nil }
        return String(format: "音声の速度が実時間と一致しません（設定 %.0f Hz / 実測 %.0f Hz）。録音を停止しました。音声デバイスを確認して録音を開始し直してください。", chunk.sampleRate, measured)
    }

    private mutating func reset() {
        previous = nil
        windowHost = 0
        windowFrames = 0
        mismatchedWindows = 0
    }
}

/// manifest がないインポート音声では、実時間を推測しない。
/// 録音済み manifest があるときは失敗記録・時計・実ファイル長を照合する。
public enum RecordingAudioValidation {
    public static func validate(stats: TrackStatsSnapshot, fileDuration: Double? = nil, recordingDuration: Double? = nil) throws {
        if let failure = stats.failure { throw failure }
        if let lastAudio = stats.lastChunkTimelineEnd, lastAudio > 0 {
            // 途切れたまま終わったトラックは、停止時に末尾を無音で埋めている（SPEC §4.3）。
            let end = lastAudio + (stats.tailPaddingSeconds ?? 0)
            try check(actual: stats.writtenSeconds, expected: end, track: stats.name, detail: "音声の長さと録音時計")
            if let recordingDuration, recordingDuration > 0 {
                try check(actual: end, expected: recordingDuration, track: stats.name, detail: "最終音声と録音終了時刻")
            }
        }
        if let fileDuration {
            try check(actual: fileDuration, expected: stats.writtenSeconds, track: stats.name, detail: "保存ファイルと書き込み時間")
        }
    }

    private static func check(actual: Double, expected: Double, track: String, detail: String) throws {
        // AAC の端数、開始/停止処理の遅れ、小さなクロック偏差は許容する。
        let tolerance = max(2, expected * 0.005)
        guard actual.isFinite, expected.isFinite, abs(actual - expected) <= tolerance else {
            throw CaptureFailure(track: track, operation: "録音品質の検証", message: String(format: "%@が一致しません（%.2f 秒 / %.2f 秒）。原音を保持しました。速度・欠落を確認してから再処理してください。", detail, actual, expected))
        }
    }
}
