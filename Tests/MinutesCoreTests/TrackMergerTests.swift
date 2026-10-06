import Foundation
import MinutesCore
import Testing

@Suite("TrackMerger / 話者ラベル")
struct TrackMergerTests {
    @Test("時刻でマージし、system の話者を spk_n に正規化、mic は me")
    func merge() {
        let system = TranscriptionResult(segments: [
            TranscriptSegment(start: 0, end: 2, text: "A1", speakerLabel: "speaker_3"),
            TranscriptSegment(start: 5, end: 7, text: "B1", speakerLabel: "speaker_1"),
            TranscriptSegment(start: 9, end: 10, text: "A2", speakerLabel: "speaker_3"),
        ])
        let mic = TranscriptionResult(segments: [
            TranscriptSegment(start: 2.5, end: 4.5, text: "me1"),
            TranscriptSegment(start: 5, end: 6, text: "me2 overlapping"),
        ])
        let output = TrackMerger.merge(TrackMerger.Input(system: system, mic: mic))
        #expect(output.segments.map(\.text) == ["A1", "me1", "B1", "me2 overlapping", "A2"])
        #expect(output.segments.map(\.id) == [1, 2, 3, 4, 5])
        #expect(output.segments[0].speaker == "spk_0")
        #expect(output.segments[2].speaker == "spk_1")
        #expect(output.segments[4].speaker == "spk_0")
        #expect(output.segments[1].speaker == "me")
        #expect(output.segments[1].track == "mic")
        #expect(output.speakers.map(\.label) == ["spk_0", "spk_1", "me"])
        #expect(output.speakers[0].providerLabel == "speaker_3")
    }

    @Test("同時刻は system を先に、片トラックのみでも動く")
    func tieAndSingle() {
        let system = TranscriptionResult(segments: [TranscriptSegment(start: 1, end: 2, text: "sys", speakerLabel: "A")])
        let mic = TranscriptionResult(segments: [TranscriptSegment(start: 1, end: 2, text: "mic")])
        let both = TrackMerger.merge(TrackMerger.Input(system: system, mic: mic))
        #expect(both.segments.map(\.text) == ["sys", "mic"])
        let micOnly = TrackMerger.merge(TrackMerger.Input(system: nil, mic: mic))
        #expect(micOnly.segments.count == 1)
        #expect(micOnly.speakers.map(\.label) == ["me"])
    }

    @Test("SpeakerLabelNormalizer は出現順に採番する")
    func normalizer() {
        var normalizer = SpeakerLabelNormalizer()
        #expect(normalizer.label(for: "B") == "spk_0")
        #expect(normalizer.label(for: "A") == "spk_1")
        #expect(normalizer.label(for: "B") == "spk_0")
        #expect(normalizer.label(for: nil) == nil)
        #expect(normalizer.providerLabelByNormalized["spk_1"] == "A")
    }

    @Test("時間重なり最大の話者を割り当て、重なりなしは最近接、それもなければ引き継ぐ")
    func overlap() {
        let turns = [SpeakerTurn(speaker: "s0", start: 0, end: 5), SpeakerTurn(speaker: "s1", start: 5, end: 10)]
        #expect(SpeakerOverlap.bestSpeaker(start: 1, end: 3, turns: turns) == "s0")
        #expect(SpeakerOverlap.bestSpeaker(start: 4, end: 7, turns: turns) == "s1")
        #expect(SpeakerOverlap.bestSpeaker(start: 10.2, end: 10.4, turns: turns) == "s1")
        #expect(SpeakerOverlap.bestSpeaker(start: 20, end: 21, turns: turns) == nil)
        let words = [
            TranscriptWord(text: "a", start: 1, end: 2),
            TranscriptWord(text: "b", start: 20, end: 21),
            TranscriptWord(text: "c", start: 6, end: 7),
        ]
        let assigned = SpeakerOverlap.assign(words: words, turns: turns)
        #expect(assigned.map(\.speakerLabel) == ["s0", "s0", "s1"])
    }
}
