import AVFoundation
import Foundation

/// 音声ファイルの読み書き・変換ユーティリティ（16 kHz mono を内部形式とする）。
public enum AudioFileTools {
    public static let sttSampleRate = 16_000.0

    public static func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }

    public static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// 任意の音声ファイルを 16 kHz mono Float32 に変換して読み込む。`from` / `to`（秒）で区間だけを読める。
    public static func loadMono16k(_ url: URL, from start: Double = 0, to end: Double? = nil) throws -> [Float] {
        try load(url, targetSampleRate: sttSampleRate, from: start, to: end)
    }

    public static func load(_ url: URL, targetSampleRate: Double, from start: Double = 0, to end: Double? = nil) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw TranscriptionError.unsupportedAudio("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        guard let resampler = Resampler(outputSampleRate: targetSampleRate) else {
            throw AudioCaptureError.conversionFailed("出力形式を作れません")
        }
        let sourceRate = file.processingFormat.sampleRate
        let firstFrame = min(file.length, max(0, Int64((max(0, start) * sourceRate).rounded())))
        let lastFrame = end.map { min(file.length, max(firstFrame, Int64(($0 * sourceRate).rounded()))) } ?? file.length
        guard lastFrame > firstFrame else { return [] }
        let readFormat = file.processingFormat
        let chunkFrames: AVAudioFrameCount = 65_536
        var output: [Float] = []
        output.reserveCapacity(Int(Double(lastFrame - firstFrame) * targetSampleRate / sourceRate) + 1024)
        file.framePosition = firstFrame
        while file.framePosition < lastFrame {
            let remaining = AVAudioFrameCount(min(Int64(chunkFrames), lastFrame - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: remaining) else { break }
            try file.read(into: buffer, frameCount: remaining)
            if buffer.frameLength == 0 { break }
            let mono = downmixToMono(buffer)
            let converted = try resampler.convert(mono)
            append(converted, to: &output)
        }
        if let tail = resampler.flush() { append(tail, to: &output) }
        return output
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to output: inout [Float]) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }

    /// 多チャンネル planar Float32 → mono（平均）。
    public static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard buffer.format.channelCount > 1, let data = buffer.floatChannelData else { return buffer }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let pointer = data[channel]
            for frame in 0..<frames { mono[frame] += pointer[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { mono[frame] *= scale }
        return PCMChunk.monoBuffer(samples: mono, sampleRate: buffer.format.sampleRate) ?? buffer
    }

    // MARK: - WAV

    /// 16-bit PCM WAV をメモリ上に作る。
    public static func wavData(samples: [Float], sampleRate: Double) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func appendLE32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func appendLE16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE32(16)
        appendLE16(1) // PCM
        appendLE16(1) // mono
        appendLE32(UInt32(sampleRate))
        appendLE32(UInt32(sampleRate) * 2)
        appendLE16(2)
        appendLE16(16)
        data.append(contentsOf: Array("data".utf8))
        appendLE32(UInt32(dataSize))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (index, sample) in samples.enumerated() {
            let clamped = max(-1, min(1, sample))
            pcm[index] = Int16(clamped * Float(Int16.max))
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public static func writeWAV(samples: [Float], sampleRate: Double, to url: URL) throws {
        try wavData(samples: samples, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    // MARK: - FLAC

    /// 送信用に FLAC（可逆圧縮）へ写した一時ファイルを作る。呼び出し側がフォルダごと消す。
    /// 16 kHz 16-bit の会議音声は 4 割前後の大きさになり、サンプルは変わらない（60 分で数秒。2026-09-30 実測）。
    public static func flacCopy(of url: URL) throws -> URL {
        let input = try AVAudioFile(forReading: url)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-flac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".flac")
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: input.fileFormat.sampleRate,
                AVNumberOfChannelsKey: input.fileFormat.channelCount,
                AVLinearPCMBitDepthKey: 16,
            ]
            let writer = try AVAudioFile(forWriting: output, settings: settings, commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
            let chunkFrames: AVAudioFrameCount = 65_536
            guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunkFrames) else {
                throw AudioCaptureError.conversionFailed("FLAC 変換のバッファを作れません")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunkFrames)
                if buffer.frameLength == 0 { break }
                try writer.write(from: buffer)
            }
            writer.close()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return output
    }

    // MARK: - AAC

    /// mono Float32 サンプル列を AAC (.m4a) に書き出す。
    public static func writeAAC(samples: [Float], sampleRate: Double, to url: URL, bitrate: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 32_768
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + chunk)
            guard let buffer = PCMChunk.monoBuffer(samples: Array(samples[index..<end]), sampleRate: sampleRate) else { break }
            try file.write(from: buffer)
            index = end
        }
    }

    /// 任意の音声ファイルを 16 kHz mono AAC に再エンコードする（OpenAI の 25 MB 上限対策）。
    public static func transcodeToAAC(input: URL, output: URL, bitrate: Int) throws {
        let samples = try loadMono16k(input)
        try writeAAC(samples: samples, sampleRate: sttSampleRate, to: output, bitrate: bitrate)
    }

    // MARK: - Splitting

    /// 目標長ごとに、前後 `searchWindowSeconds` 内で最も静かな `frameSeconds` 窓の中心を分割点として返す。
    public static func quietSplitPoints(
        samples: [Float],
        sampleRate: Double,
        targetChunkSeconds: Double,
        searchWindowSeconds: Double = 30,
        frameSeconds: Double = 0.2
    ) -> [Double] {
        let duration = Double(samples.count) / sampleRate
        guard targetChunkSeconds > 0, duration > targetChunkSeconds else { return [] }
        let frameLength = max(1, Int(frameSeconds * sampleRate))
        var points: [Double] = []
        var boundary = targetChunkSeconds
        var lastPoint = 0.0
        while boundary < duration - 1 {
            let searchStart = max(lastPoint + 1, boundary - searchWindowSeconds)
            let searchEnd = min(duration - 1, boundary + searchWindowSeconds)
            var bestTime = boundary
            var bestLevel = Float.greatestFiniteMagnitude
            var position = Int(searchStart * sampleRate)
            let endPosition = Int(searchEnd * sampleRate) - frameLength
            while position < endPosition {
                let level = AudioLevel.rmsDB(samples[position..<(position + frameLength)])
                if level < bestLevel {
                    bestLevel = level
                    bestTime = (Double(position) + Double(frameLength) / 2) / sampleRate
                }
                position += frameLength / 2
            }
            points.append(bestTime)
            lastPoint = bestTime
            boundary = bestTime + targetChunkSeconds
        }
        return points
    }
}
