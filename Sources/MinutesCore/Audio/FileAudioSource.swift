import Foundation

/// 音声ファイルを 16 kHz mono の AudioChunk ストリームとして流す（録音なしで live 経路を評価するため）。
public enum FileAudioSource {
    public struct Output: Sendable {
        public var stream: AsyncStream<AudioChunk>
        public var durationSeconds: Double
    }

    /// `realtime` が true なら実時間のペースで、false なら可能な限り速く流す。
    public static func stream(url: URL, chunkSeconds: Double = 0.1, realtime: Bool = true) throws -> Output {
        let samples = try AudioFileTools.loadMono16k(url)
        let rate = AudioFileTools.sttSampleRate
        let chunkFrames = max(1, Int(chunkSeconds * rate))
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
        let task = Task.detached {
            let start = HostClock.nowSeconds()
            var index = 0
            while index < samples.count, !Task.isCancelled {
                let end = min(samples.count, index + chunkFrames)
                let startTime = Double(index) / rate
                if realtime {
                    let target = start + startTime
                    let now = HostClock.nowSeconds()
                    if target > now { try? await Task.sleep(for: .seconds(target - now)) }
                }
                continuation.yield(AudioChunk(samples: Array(samples[index..<end]), sampleRate: rate, startTime: startTime))
                index = end
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return Output(stream: stream, durationSeconds: Double(samples.count) / rate)
    }
}
