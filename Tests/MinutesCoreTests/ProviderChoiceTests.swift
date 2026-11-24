import Foundation
@testable import MinutesCore
import Testing

@Suite("文字起こしと要約の手段の組み合わせ（SPEC §5.6）")
struct ProviderChoiceTests {
    @Test("文字起こしを Minutes クラウドに変えたら、要約も Minutes クラウドにする（あとで変えた要約は、同じ選択では戻さない）")
    func linksSummaryToCloudTranscription() {
        var settings = AppSettings()
        settings.summaryProvider = .codex
        settings.chooseFinalProvider(MinutesCloudTranscriber.providerID)
        #expect(settings.finalProviderId == MinutesCloudTranscriber.providerID)
        #expect(settings.resolvedSummaryProvider == .minutesCloud)
        #expect(settings.providerMismatch == nil)

        // 要約だけをあとで Codex にした人の選択は、同じ文字起こしを選び直しても変えない
        settings.summaryProvider = .codex
        settings.chooseFinalProvider(MinutesCloudTranscriber.providerID)
        #expect(settings.resolvedSummaryProvider == .codex)
        #expect(settings.providerMismatch == .summaryElsewhere(.codex))

        // ほかの文字起こしに変えても、要約は勝手に変えない
        settings.chooseFinalProvider("elevenlabs.scribe_v2")
        #expect(settings.resolvedSummaryProvider == .codex)
        #expect(settings.providerMismatch == nil)
    }

    @Test("組み合わせの知らせ: 文字起こしだけ Minutes クラウド、要約だけ Minutes クラウド、要約しない")
    func mismatch() {
        var settings = AppSettings()
        settings.finalProviderId = MinutesCloudTranscriber.providerID
        settings.summaryProvider = .claudeCode
        #expect(settings.providerMismatch == .summaryElsewhere(.claudeCode))
        settings.summaryProvider = SummaryProvider.none
        #expect(settings.providerMismatch == nil)

        settings.finalProviderId = "local.speechanalyzer+fluidaudio"
        settings.summaryProvider = .minutesCloud
        #expect(settings.providerMismatch == .cloudSummaryWithoutCloudTranscription)
        settings.summaryProvider = .anthropic
        #expect(settings.providerMismatch == nil)

        // 要約の既定（未選択）は Codex
        settings.finalProviderId = MinutesCloudTranscriber.providerID
        settings.summaryProvider = nil
        #expect(settings.providerMismatch == .summaryElsewhere(.codex))
    }
}
