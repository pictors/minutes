import MinutesKit
import Testing

/// アカウントを消す前に打ち込む文字（iPhone の「アカウントを消す」の画面）。アドレスは架空。
@Suite("アカウントの削除の確認")
struct MinutesCloudDeletionConfirmationTests {
    private static func confirmation(_ email: String?) -> MinutesCloudDeletionConfirmation {
        MinutesCloudDeletionConfirmation(user: MinutesCloudUser(id: "fictional-user", email: email))
    }

    @Test("ふつうのアドレスは、そのアドレスを打ち込むと合う（前後の空白と大文字・小文字は見ない）")
    func email() {
        let c = Self.confirmation("taro@example.test")
        #expect(c.expected == .email("taro@example.test"))
        #expect(c.matches("taro@example.test"))
        #expect(c.matches("  Taro@Example.TEST \n"))
        #expect(!c.matches("taro@example.tes"))
        #expect(!c.matches("taro@example.test.jp"))
        #expect(!c.matches(MinutesCloudDeletionConfirmation.word))
        #expect(!c.matches(MinutesCloudDeletionConfirmation.asciiWord))
        #expect(!c.matches(""))
        #expect(!c.matches("   "))
    }

    @Test("Apple の「メールを非公開」のアドレスは「削除」（かなのまま・英字の delete も）で合う（アドレスでは合わない）")
    func privateRelay() {
        let relay = "x7k2q9m4p1@privaterelay.appleid.com"
        let c = Self.confirmation(relay)
        #expect(c.expected == .word)
        #expect(c.matches("削除"))
        #expect(c.matches(" 削除 "))
        #expect(c.matches("さくじょ"))
        #expect(c.matches("delete"))
        #expect(c.matches(" DELETE "))
        #expect(!c.matches(relay))
        #expect(!c.matches("削"))
        #expect(!c.matches("delet"))
        #expect(!c.matches("消す"))
        #expect(!c.matches(""))
    }

    @Test("アドレスが分からない・空・形が違うときは「削除」で合い、空の入力ではけっして合わない")
    func unknown() {
        for email in [nil, "", "   ", "not-an-address"] as [String?] {
            let c = Self.confirmation(email)
            #expect(c.expected == .word)
            #expect(c.matches("削除"))
            #expect(!c.matches(""))
            #expect(!c.matches(" "))
            #expect(!c.matches(email ?? ""))
        }
        let signedOut = MinutesCloudDeletionConfirmation(user: nil)
        #expect(signedOut.expected == .word)
        #expect(!signedOut.matches(""))
    }
}
