import Foundation
import MinutesCore
import Testing

@Suite("引数パーサ / .env / JSON")
struct SupportTests {
    @Test("オプション・フラグ・位置引数・繰り返し・= 形式")
    func arguments() throws {
        let spec = ArgumentSpec(options: ["app", "out", "num"], flags: ["no-mic", "json"])
        let parsed = try ArgumentParser.parse(["dir", "--app", "com.google.Chrome", "--app=com.microsoft.teams2", "--no-mic", "--out", "x", "--num", "3", "--", "--literal"], spec: spec)
        #expect(parsed.positionals == ["dir", "--literal"])
        #expect(parsed.values("app") == ["com.google.Chrome", "com.microsoft.teams2"])
        #expect(parsed.list("app") == ["com.google.Chrome", "com.microsoft.teams2"])
        #expect(parsed.has("no-mic"))
        #expect(!parsed.has("json"))
        #expect(parsed.value("out") == "x")
        #expect(try parsed.int("num") == 3)
        #expect(try ArgumentParser.parse(["--app", "a,b, c"], spec: spec).list("app") == ["a", "b", "c"])
    }

    @Test("エラー: 不明なオプション・値なし・不正な数値")
    func argumentErrors() {
        let spec = ArgumentSpec(options: ["num"], flags: [])
        #expect(throws: ArgumentError.unknownOption("bogus")) {
            _ = try ArgumentParser.parse(["--bogus"], spec: spec)
        }
        #expect(throws: ArgumentError.missingValue(option: "num")) {
            _ = try ArgumentParser.parse(["--num"], spec: spec)
        }
        #expect(throws: ArgumentError.self) {
            _ = try ArgumentParser.parse(["--num", "abc"], spec: spec).int("num")
        }
    }

    @Test(".env のパース")
    func dotEnv() {
        let parsed = DotEnv.parse("""
        # comment
        ELEVENLABS_API_KEY=abc123
        export OPENAI_API_KEY="sk-xyz"\u{20}
        QUOTED='single # not comment'
        WITH_COMMENT=value # trailing
        INVALID LINE
        EMPTY=
        """)
        #expect(parsed["ELEVENLABS_API_KEY"] == "abc123")
        #expect(parsed["OPENAI_API_KEY"] == "sk-xyz")
        #expect(parsed["QUOTED"] == "single # not comment")
        #expect(parsed["WITH_COMMENT"] == "value")
        #expect(parsed["EMPTY"] == "")
        #expect(parsed.count == 5)
    }

    @Test("TranscriptDocument の JSON は snake_case で往復する")
    func documentRoundTrip() throws {
        let document = TranscriptDocument(
            meeting: .init(id: "m1", title: "定例", startedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: 60, sourceDirectory: "/tmp/x"),
            provider: "elevenlabs.scribe_v2",
            language: "ja",
            speakers: [.init(label: "spk_0", name: nil, providerLabel: "speaker_0", track: "system")],
            segments: [.init(id: 1, track: "system", tStart: 0.5, tEnd: 2.0, speaker: "spk_0", text: "こんにちは", confidence: 0.9)],
            providerMeta: ["model_id": "scribe_v2"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_100) // ISO 8601 は秒精度
        )
        let data = try JSONCoding.encoder().encode(document)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"t_start\" : 0.5"))
        #expect(json.contains("\"schema_version\" : 1"))
        #expect(json.contains("\"provider_label\" : \"speaker_0\""))
        let decoded = try JSONCoding.decoder().decode(TranscriptDocument.self, from: data)
        #expect(decoded == document)
        #expect(document.formattedTranscript() == "[00:00:00] spk_0: こんにちは")
    }

    @Test("時刻フォーマット")
    func timeFormatting() {
        #expect(TimeFormatting.hms(3725) == "01:02:05")
        #expect(TimeFormatting.mmss(65.25) == "01:05.2")
    }

    @Test("bundle id のマッチ（helper を含む前方一致）")
    func bundleMatching() {
        #expect(BundleIDMatcher.matches("com.google.Chrome", target: "com.google.Chrome"))
        #expect(BundleIDMatcher.matches("com.google.Chrome.helper", target: "com.google.Chrome"))
        #expect(BundleIDMatcher.matches("com.google.Chrome.helper.renderer", target: "com.google.Chrome"))
        #expect(!BundleIDMatcher.matches("com.google.Chromecast", target: "com.google.Chrome"))
        #expect(!BundleIDMatcher.matches(nil, target: "com.google.Chrome"))
        #expect(BundleIDMatcher.matches("com.microsoft.teams2", targets: ["com.google.Chrome", "com.microsoft.teams2"]))
    }
}
