import Foundation
@testable import MinutesCore
import Testing

@Suite("Minutes クラウドに任せるか、自分で選ぶか（SPEC §5.6）")
struct ProviderChoiceTests {
    private let cloudID = MinutesCloudTranscriber.providerID

    @Test("任せると文字起こしと要約の両方が Minutes クラウドになり、戻すと自分で選んでいた手段に戻る")
    func switchesBothAndRestores() {
        var settings = AppSettings()
        settings.finalProviderId = "openai.gpt-4o-transcribe-diarize"
        settings.summaryProvider = .claudeCode
        #expect(!settings.usesMinutesCloud)

        settings.setUsesMinutesCloud(true)
        #expect(settings.usesMinutesCloud)
        #expect(settings.finalProviderId == cloudID && settings.resolvedSummaryProvider == .minutesCloud)
        #expect(settings.ownFinalProviderId == "openai.gpt-4o-transcribe-diarize" && settings.ownSummaryProvider == .claudeCode)

        settings.setUsesMinutesCloud(false)
        #expect(!settings.usesMinutesCloud)
        #expect(settings.finalProviderId == "openai.gpt-4o-transcribe-diarize" && settings.resolvedSummaryProvider == .claudeCode)
    }

    @Test("覚えている手段がなければ、戻したときは既定（ElevenLabs と Codex）")
    func restoresDefaults() {
        var settings = AppSettings()
        settings.finalProviderId = cloudID
        settings.summaryProvider = .minutesCloud
        settings.setUsesMinutesCloud(false)
        #expect(settings.finalProviderId == AppSettings().finalProviderId)
        #expect(settings.resolvedSummaryProvider == .codex)
    }

    @Test("片方だけ Minutes クラウドの古い設定はそろえる: 文字起こしが Minutes クラウドなら任せる、要約だけなら要約しない")
    func normalizesMixedSettings() {
        var transcriptionOnly = AppSettings()
        transcriptionOnly.finalProviderId = cloudID
        transcriptionOnly.summaryProvider = .codex
        let transcriptionOnlyChanged = transcriptionOnly.normalizeProcessingMode()
        #expect(transcriptionOnlyChanged)
        #expect(transcriptionOnly.usesMinutesCloud && transcriptionOnly.resolvedSummaryProvider == .minutesCloud)
        // それまでの要約は「自分で選ぶ」に覚えていて、戻すと Codex に戻る
        #expect(transcriptionOnly.ownSummaryProvider == .codex)
        transcriptionOnly.setUsesMinutesCloud(false)
        #expect(transcriptionOnly.resolvedSummaryProvider == .codex)

        var summaryOnly = AppSettings()
        summaryOnly.finalProviderId = "elevenlabs.scribe_v2"
        summaryOnly.summaryProvider = .minutesCloud
        let summaryOnlyChanged = summaryOnly.normalizeProcessingMode()
        #expect(summaryOnlyChanged)
        // ほかの事業者へ文字起こしを送り始めないように、要約しない
        #expect(!summaryOnly.usesMinutesCloud && summaryOnly.resolvedSummaryProvider == SummaryProvider.none)

        var consistent = AppSettings()
        consistent.setUsesMinutesCloud(true)
        let consistentChanged = consistent.normalizeProcessingMode()
        #expect(!consistentChanged)
        var own = AppSettings()
        own.summaryProvider = .anthropic
        let ownChanged = own.normalizeProcessingMode()
        #expect(!ownChanged)
    }

    @Test("自分で選んでいた手段は settings.json に往復する")
    func roundTrip() throws {
        var settings = AppSettings()
        settings.finalProviderId = "local.speechanalyzer+fluidaudio"
        settings.summaryProvider = .anthropic
        settings.setUsesMinutesCloud(true)
        let decoded = try JSONCoding.decoder().decode(AppSettings.self, from: JSONCoding.encoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.ownFinalProviderId == "local.speechanalyzer+fluidaudio" && decoded.ownSummaryProvider == .anthropic)
    }
}
