import Foundation
import MinutesKit
import Testing

/// 要約の文と担当の中の話者の見せ方（SummarySpeakerText）。会議と人名は架空。
@Suite("要約の中の話者の見せ方")
struct SummarySpeakerTextTests {
    private struct Cases: Decodable {
        struct Case: Decodable {
            var text: String
            var expected: String
        }

        var names: [String: String]
        var cases: [Case]
    }

    @Test("文の中のラベルを名前か「話者 N」に替える（サーバーの共有のページと同じ答えの表）")
    func sharedCases() throws {
        let url = try #require(Bundle.module.url(forResource: "summary-speaker-text-cases", withExtension: "json", subdirectory: "Fixtures"))
        let table = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: url))
        #expect(table.cases.count >= 10)
        let name = { (label: String) -> String in
            table.names[label] ?? "話者 \((SummarySpeakerText.labelNumber(label) ?? -1) + 1)"
        }
        for item in table.cases {
            #expect(SummarySpeakerText.replacingLabels(in: item.text, name: name) == item.expected, "\(item.text)")
        }
    }

    @Test("ラベルがなければ文はそのまま（名前を聞かない）")
    func untouched() {
        var asked = 0
        let text = "架空の結論です。\n- me が日程を送る"
        #expect(SummarySpeakerText.replacingLabels(in: text) { _ in asked += 1; return "x" } == text)
        #expect(asked == 0)
        #expect(SummarySpeakerText.replacingLabels(in: "") { _ in "x" } == "")
    }

    @Test("ラベルの番号は spk_ と数字だけの形から取る")
    func labelNumber() {
        #expect(SummarySpeakerText.labelNumber("spk_0") == 0)
        #expect(SummarySpeakerText.labelNumber("spk_12") == 12)
        for label in ["spk_", "spk_1a", "me", "agent", "c0_1", "manual_x", "SPK_1", "spk_-1", "spk_１"] {
            #expect(SummarySpeakerText.labelNumber(label) == nil, "\(label)")
        }
    }

    @Test("担当「me」を自分として出すのは、会議に「me」の話者がいるときか、手で足したやることのときだけ")
    func ownerIsSelf() {
        let generated = MinutesSummary.ActionItem(text: "架空の資料を送る", owner: "me", kind: .ownCommitment, due: nil, evidence: [1])
        let manual = MinutesSummary.ActionItem(text: "架空の日程を決める", owner: "me", kind: .ownCommitment, due: nil, evidence: [], manual: true)
        let other = MinutesSummary.ActionItem(text: "架空の下書き", owner: "spk_1", kind: .theirTask, due: nil, evidence: [2])
        // Mac の 2 トラック・同期した Mac の会議
        #expect(SummarySpeakerText.ownerIsSelf(generated, meetingHasSelfSpeaker: true))
        // iPhone・Watch の 1 トラック: 要約の「me」は推し量りなので自分とみなさない。手で足したものは自分
        #expect(!SummarySpeakerText.ownerIsSelf(generated, meetingHasSelfSpeaker: false))
        #expect(SummarySpeakerText.ownerIsSelf(manual, meetingHasSelfSpeaker: false))
        // まだ文字起こしを読んでいない: これまでどおり自分として出す
        #expect(SummarySpeakerText.ownerIsSelf(generated, meetingHasSelfSpeaker: nil))
        #expect(!SummarySpeakerText.ownerIsSelf(other, meetingHasSelfSpeaker: true))
    }
}
