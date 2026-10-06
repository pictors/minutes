import Foundation
import MinutesCore
import Testing

@Suite("プロバイダのレスポンスパーサ（golden）")
struct ProviderParserTests {
    func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test("ElevenLabs: words[] を話者付きセグメントに畳む（audio_event は除外）")
    func elevenLabs() throws {
        let response = try ElevenLabsTranscriber.parseResponse(fixture("elevenlabs_scribe_v2"))
        #expect(response.languageCode == "jpn")
        #expect(response.words.count == 15)
        let result = ElevenLabsTranscriber.makeResult(from: response)
        #expect(result.words?.count == 14)
        #expect(result.segments.count == 2)
        #expect(result.segments[0].text == "おはようございます。今日の議題は新機能のリリース日です。")
        #expect(result.segments[0].speakerLabel == "speaker_0")
        #expect(result.segments[0].start == 0.2)
        #expect(result.segments[0].end == 4.0)
        #expect(result.segments[1].text == "はい、来週の金曜日でお願いします。")
        #expect(result.segments[1].speakerLabel == "speaker_1")
        #expect(result.speakerLabels == ["speaker_0", "speaker_1"])
        let confidence = try #require(result.segments[0].confidence)
        #expect(confidence > 0.7 && confidence < 1.0)
    }

    @Test("OpenAI: diarized_json をセグメントに変換（既知話者名はそのまま）")
    func openAI() throws {
        let response = try OpenAITranscriber.parseResponse(fixture("openai_diarized"))
        #expect(response.duration == 9.5)
        #expect(response.segments.count == 3)
        let result = OpenAITranscriber.makeResult(from: response)
        #expect(result.segments.map(\.speakerLabel) == ["A", "B", "tanaka"])
        #expect(result.segments[1].text == "はい、来週の金曜日でお願いします。")
        #expect(result.segments[1].start == 5.2)
    }

    @Test("壊れた JSON は invalidResponse")
    func invalid() {
        #expect(throws: TranscriptionError.self) {
            _ = try ElevenLabsTranscriber.parseResponse(Data("{".utf8))
        }
        #expect(throws: TranscriptionError.self) {
            _ = try OpenAITranscriber.parseResponse(Data("[]".utf8))
        }
    }

    @Test("multipart の形式（メモリとファイル書き出しで同じ body）")
    func multipart() throws {
        var form = MultipartFormData(boundary: "B")
        form.addField(name: "model_id", value: "scribe_v2")
        form.addField(name: "keyterms", value: "田中")
        form.addField(name: "keyterms", value: "Pictors")
        form.addFile(name: "file", filename: "a.wav", contentType: "audio/wav", data: Data([1, 2, 3]))
        let body = String(decoding: try form.encoded(), as: UTF8.self)
        #expect(body.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        #expect(body.components(separatedBy: "name=\"keyterms\"").count == 3)
        #expect(body.contains("Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n"))
        #expect(body.hasSuffix("--B--\r\n"))
        #expect(form.contentType == "multipart/form-data; boundary=B")
        #expect(MultipartFormData.mimeType(forExtension: "m4a") == "audio/mp4")
        // ファイル参照は write(to:) でストリーム書き出しし、encoded() と同じ body になる
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-multipart-\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        var referenced = MultipartFormData(boundary: "B")
        referenced.addField(name: "model_id", value: "scribe_v2")
        referenced.addField(name: "keyterms", value: "田中")
        referenced.addField(name: "keyterms", value: "Pictors")
        referenced.addFile(name: "file", filename: "a.wav", contentType: "audio/wav", url: audio)
        let written = try referenced.writeTemporaryFile()
        defer { try? FileManager.default.removeItem(at: written) }
        #expect(try Data(contentsOf: written) == Data(body.utf8))
        #expect(try referenced.encoded() == Data(body.utf8))
    }
}
