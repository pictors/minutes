import Foundation
import MinutesCore
import Testing

/// Pictors のサーバー（キーなし）とのやり取りの形を固定する。
/// SummaryInput の書き方は、後処理の要約の指紋（PipelineFingerprint）にも入るので、変わると既存の会議の要約がすべてやり直しになる。
/// 同じファイルをサーバー（非公開）のテストの golden にも写す。変えるときは両方をそろえる。
@Suite("キーなしのやり取りの形")
struct MinutesCloudContractTests {
    static let goldenName = "minutes-cloud-summary-input"

    /// 架空の会議の要約の入力（golden の元）
    static func fictionalSummaryInput() -> SummaryInput {
        SummaryInput(
            meetingTitle: "架空の Mac の会議",
            startedAt: Date(timeIntervalSince1970: 1_795_136_400), // 2026-11-20T01:00:00Z
            attendees: [Attendee(name: "架空の山田"), Attendee(name: "架空の佐藤", email: "kakuu@example.test")],
            segments: [
                TranscriptDocument.Segment(id: 0, track: "system", tStart: 0, tEnd: 3.2, speaker: "spk_0", text: "架空の議題を始めます。", confidence: 0.9),
                TranscriptDocument.Segment(id: 1, track: "mic", tStart: 3.5, tEnd: 6.4, speaker: "me", text: "架空の資料を共有します。"),
            ],
            speakerNames: ["spk_0": "架空の山田", "me": "自分"],
            previousSummaryMd: nil,
            meetingLanguage: .ja,
            outputLanguage: .ja
        )
    }

    @Test("SummaryInput の書き方は golden と同じ（要約の指紋とサーバーへの依頼）")
    func summaryInputEncoding() throws {
        let encoded = try JSONCoding.encoder().encode(Self.fictionalSummaryInput())
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(Self.goldenName).json")
        if ProcessInfo.processInfo.environment["MINUTES_RECORD_GOLDEN"] == "1" {
            try encoded.write(to: source)
        }
        let url = try #require(Bundle.module.url(forResource: Self.goldenName, withExtension: "json", subdirectory: "Fixtures"))
        let golden = try Data(contentsOf: url)
        #expect(encoded == golden, "SummaryInput の書き方が変わった（golden: Fixtures/\(Self.goldenName).json）")
    }
}
