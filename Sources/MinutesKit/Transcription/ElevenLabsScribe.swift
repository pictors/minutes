import Foundation

/// ElevenLabs Scribe の文字起こしの応答の読み方（SPEC §5.3）。
/// 直接 ElevenLabs に送ったとき（MinutesCore の ElevenLabsTranscriber）と、Pictors のサーバーの GET /v1/recordings/:id/stt（キーなし）の両方で使う。
/// 形: language_code, language_probability, text, words[]{text,type,logprob,start,end,speaker_id}, transcription_id, audio_duration_secs
public enum ElevenLabsScribe {
    public struct Response: Decodable, Sendable {
        public struct Word: Decodable, Sendable {
            public var text: String
            /// "word" | "spacing" | "audio_event"
            public var type: String
            public var logprob: Double?
            public var start: Double?
            public var end: Double?
            public var speakerId: String?
        }

        public var languageCode: String?
        public var languageProbability: Double?
        public var text: String
        public var words: [Word]
        public var transcriptionId: String?
        public var audioDurationSecs: Double?
    }

    public static func parseResponse(_ data: Data) throws -> Response {
        do {
            return try JSONCoding.decoder().decode(Response.self, from: data)
        } catch {
            throw TranscriptionError.invalidResponse(provider: "elevenlabs", detail: "\(error)")
        }
    }

    /// words[] を TranscriptWord / TranscriptSegment に畳む。audio_event は除外する。
    public static func makeResult(from response: Response, foldingOptions: SegmentFoldingOptions = SegmentFoldingOptions(), meta: [String: String] = [:]) -> TranscriptionResult {
        var words: [TranscriptWord] = []
        words.reserveCapacity(response.words.count)
        var lastEnd = 0.0
        for word in response.words where word.type != "audio_event" {
            let start = word.start ?? lastEnd
            let end = word.end ?? start
            lastEnd = max(lastEnd, end)
            let confidence = word.logprob.map { exp($0) }
            words.append(TranscriptWord(text: word.text, start: start, end: end, speakerLabel: word.speakerId, confidence: confidence))
        }
        let segments = SegmentFolder.fold(words: words, options: foldingOptions)
        return TranscriptionResult(segments: segments, words: words, providerMeta: meta)
    }
}
