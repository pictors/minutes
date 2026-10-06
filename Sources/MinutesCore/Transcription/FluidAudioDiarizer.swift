import FluidAudio
import Foundation

/// FluidAudio のオフライン話者分離（pyannote community-1 + VBx）のラッパ。
/// モデルは初回に Hugging Face（FluidInference/speaker-diarization-coreml）から
/// ~/Library/Application Support/FluidAudio/Models/ にダウンロードされる（音声自体は端末外に出ない）。
public enum FluidAudioDiarizer {
    public static let identifier = "fluidaudio.offline(pyannote-community-1+vbx)"

    /// 16 kHz mono サンプル列を話者区間に分ける。無音のみの場合は空配列。
    /// - Parameters:
    ///   - numSpeakers: 話者数が分かっていれば指定する（カレンダー参加者数 − 1 など）。未指定だと過分割しやすい。
    ///   - clusteringThreshold: クラスタリング閾値（FluidAudio 既定 0.6）。大きいほど話者をまとめる。
    public static func diarize(
        samples: [Float],
        numSpeakers: Int? = nil,
        clusteringThreshold: Double? = nil,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        var config = OfflineDiarizerConfig.default
        if let numSpeakers, numSpeakers > 0 {
            config.clustering.numSpeakers = numSpeakers
        }
        if let clusteringThreshold {
            config.clustering.threshold = clusteringThreshold
        }
        let manager = OfflineDiarizerManager(config: config)
        do {
            try await manager.prepareModels()
        } catch {
            throw TranscriptionError.assetsUnavailable("FluidAudio モデルの準備に失敗: \(error)")
        }
        do {
            let result = try await manager.process(audio: samples, progressCallback: progress)
            return result.segments
                .map { SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
                .sorted { $0.start < $1.start }
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error { return [] }
            throw TranscriptionError.diarizationFailed("\(error)")
        } catch {
            throw TranscriptionError.diarizationFailed("\(error)")
        }
    }
}
