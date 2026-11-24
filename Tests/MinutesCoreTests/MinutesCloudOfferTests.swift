import Foundation
@testable import MinutesCore
import Testing

@Suite("Minutes クラウドを選択肢に出すか（公開までの決まり、SPEC §5.6）")
struct MinutesCloudOfferTests {
    @Test("ふつうの利用者には出さない。ログインの印がある・すでに選んでいる・隠しスイッチのどれかで出す")
    func rule() {
        #expect(!MinutesCloudOffer.isOffered(hasLogin: false, selected: false, preview: false))
        #expect(MinutesCloudOffer.isOffered(hasLogin: true, selected: false, preview: false))
        // ログアウトしても、選んでいるあいだは選択肢に残す（消えると、いまの選択を表示できない）
        #expect(MinutesCloudOffer.isOffered(hasLogin: false, selected: true, preview: false))
        #expect(MinutesCloudOffer.isOffered(hasLogin: false, selected: false, preview: true))
    }

    @Test("隠しスイッチは UserDefaults の MinutesCloudPreview（defaults write jp.pictors.minutes MinutesCloudPreview -bool YES）")
    func previewSwitch() throws {
        #expect(MinutesCloudOffer.previewDefaultsKey == "MinutesCloudPreview")
        let name = "minutes-offer-test-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!MinutesCloudOffer.isOffered(hasLogin: false, selected: false, preview: defaults.bool(forKey: MinutesCloudOffer.previewDefaultsKey)))
        defaults.set(true, forKey: MinutesCloudOffer.previewDefaultsKey)
        #expect(MinutesCloudOffer.isOffered(hasLogin: false, selected: false, preview: defaults.bool(forKey: MinutesCloudOffer.previewDefaultsKey)))
    }
}
