import AVFoundation
import Foundation

/// 取得直後の生 PCM チャンク（planar Float32）。オーディオコールバックから安全に持ち出すためにコピーする。
public struct PCMChunk: Sendable {
    /// チャンネルごとのサンプル列。
    public var channels: [[Float]]
    public var sampleRate: Double
    /// 先頭フレームのホスト時刻（tick）。不明なら 0。
    public var hostTime: UInt64
    /// 先頭フレームのデバイスサンプル時刻。不明なら NaN。
    public var sampleTime: Double

    public init(channels: [[Float]], sampleRate: Double, hostTime: UInt64, sampleTime: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.hostTime = hostTime
        self.sampleTime = sampleTime
    }

    public var channelCount: Int { channels.count }
    public var frameCount: Int { channels.first?.count ?? 0 }
    public var duration: Double { Double(frameCount) / sampleRate }

    /// AVAudioPCMBuffer（Float32、planar/interleaved どちらでも）からコピーする。
    public init?(buffer: AVAudioPCMBuffer, hostTime: UInt64, sampleTime: Double) {
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return nil }
        var channels: [[Float]] = []
        if buffer.format.commonFormat == .pcmFormatFloat32, let data = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                let base = data[0]
                for channel in 0..<channelCount {
                    var samples = [Float](repeating: 0, count: frames)
                    for frame in 0..<frames { samples[frame] = base[frame * channelCount + channel] }
                    channels.append(samples)
                }
            } else {
                for channel in 0..<channelCount {
                    channels.append(Array(UnsafeBufferPointer(start: data[channel], count: frames)))
                }
            }
        } else if buffer.format.commonFormat == .pcmFormatInt16, let data = buffer.int16ChannelData {
            let scale = 1.0 / Float(Int16.max)
            for channel in 0..<channelCount {
                var samples = [Float](repeating: 0, count: frames)
                if buffer.format.isInterleaved {
                    for frame in 0..<frames { samples[frame] = Float(data[0][frame * channelCount + channel]) * scale }
                } else {
                    for frame in 0..<frames { samples[frame] = Float(data[channel][frame]) * scale }
                }
                channels.append(samples)
            }
        } else {
            return nil
        }
        self.init(channels: channels, sampleRate: buffer.format.sampleRate, hostTime: hostTime, sampleTime: sampleTime)
    }

    /// チャンネル平均で mono にする。
    public func monoSamples() -> [Float] {
        guard channelCount > 1 else { return channels.first ?? [] }
        let frames = frameCount
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1.0 / Float(channelCount)
        for channel in channels {
            for frame in 0..<frames { mono[frame] += channel[frame] }
        }
        for frame in 0..<frames { mono[frame] *= scale }
        return mono
    }

    /// mono Float32（planar）の AVAudioPCMBuffer を作る。
    public static func monoBuffer(samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let data = buffer.floatChannelData, !samples.isEmpty {
            samples.withUnsafeBufferPointer { pointer in
                data[0].update(from: pointer.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }
}

public enum AudioLevel {
    /// RMS を dBFS で返す（無音は -120）。
    public static func rmsDB(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 1e-6 ? 20 * log10(rms) : -120
    }

    public static func rmsDB(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        return rms > 1e-6 ? 20 * log10(rms) : -120
    }
}
