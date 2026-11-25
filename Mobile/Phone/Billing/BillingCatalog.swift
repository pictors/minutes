import Foundation

/// App 内課金の商品と、購入の画面に出す文書の場所（製品版の P6）。差し替えるのはここだけ。
/// 商品は App Store Connect のサブスクリプションのグループ「Minutes Pro」の月額と年額（2026-11-25 に登録。同じ段、7 日の無料の試用）。
/// 同じ ID をサーバー（使える量）と `Mobile/PhoneTests/Minutes.storekit`（手元の試しの商品）にも書く。
/// 価格・期間・商品名・試用はアプリに書かず、StoreKit の Product（displayName・displayPrice・subscription）から出す。量はサーバーの /v1/billing から出す。
enum BillingCatalog {
    /// 月額
    static let proMonthly = "jp.pictors.minutes.pro.monthly"
    /// 年額（使える量は月額と同じく 1 か月ごと）
    static let proYearly = "jp.pictors.minutes.pro.yearly"

    /// 購入の画面に並べる商品（この順）
    static let productIDs = [proMonthly, proYearly]

    /// 利用規約（仮。公開の前に決める。自前の規約を作らないなら Apple の標準 EULA: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/ ）
    static let termsURL = URL(string: "https://minutes.tools/terms/")!

    /// プライバシーポリシー（仮。公開の前に決める）
    static let privacyURL = URL(string: "https://minutes.tools/privacy/")!
}
