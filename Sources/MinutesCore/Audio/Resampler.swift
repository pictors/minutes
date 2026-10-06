@preconcurrency import AVFoundation
import Foundation

/// AVAudioConverter のストリーミングラッパ。入力形式が変わったら内部でコンバータを作り直す。
/// 単一スレッド（1 本のシリアルキュー）から使うこと。
public final class Resampler {
    public let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    public convenience init?(outputSampleRate: Double, channels: AVAudioChannelCount = 1) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: channels, interleaved: false) else { return nil }
        self.init(outputFormat: format)
    }

    /// 1 バッファを変換する。形式が既に一致していればそのまま返す。
    public func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == outputFormat { return input }
        if converter == nil || inputFormat != input.format {
            guard let created = AVAudioConverter(from: input.format, to: outputFormat) else {
                throw AudioCaptureError.conversionFailed("AVAudioConverter を作れません: \(input.format) → \(outputFormat)")
            }
            converter = created
            inputFormat = input.format
        }
        guard let converter else { throw AudioCaptureError.conversionFailed("converter nil") }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.conversionFailed("出力バッファを確保できません")
        }
        // 入力ブロックは Sendable 扱いなので、状態はクラスに入れて捕捉する
        let state = InputState()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if state.consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw AudioCaptureError.conversionFailed(conversionError?.localizedDescription ?? "unknown")
        }
        return output
    }

    /// 内部に残ったサンプルを吐き出す（終了時）。
    public func flush() -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return nil }
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            outStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    public func reset() {
        converter = nil
        inputFormat = nil
    }

    private final class InputState: @unchecked Sendable {
        var consumed = false
    }
}

public enum AudioCaptureError: Error, LocalizedError {
    case noMatchingProcess(targets: [String])
    case tapCreationFailed(String)
    case aggregateCreationFailed(String)
    case ioProcFailed(OSStatus)
    case permissionDenied(String)
    case noInputDevice
    case conversionFailed(String)
    case fileWriteFailed(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case let .noMatchingProcess(targets):
            return "録音対象のプロセスが見つかりません: \(targets.joined(separator: ", "))（`minutes-cli processes` で確認できます）"
        case let .tapCreationFailed(detail):
            return "Process Tap を作成できません: \(detail)（システム設定 > プライバシーとセキュリティ > 画面収録とシステムオーディオ録音 の許可を確認）"
        case let .aggregateCreationFailed(detail):
            return "Aggregate Device を作成できません: \(detail)"
        case let .ioProcFailed(status):
            return "IO proc の登録に失敗しました (OSStatus \(status))"
        case let .permissionDenied(detail):
            return "権限がありません: \(detail)"
        case .noInputDevice:
            return "マイク入力デバイスがありません"
        case let .conversionFailed(detail):
            return "音声変換に失敗しました: \(detail)"
        case let .fileWriteFailed(detail):
            return "音声ファイルの書き出しに失敗しました: \(detail)"
        case let .invalidState(detail):
            return "不正な状態: \(detail)"
        }
    }
}
