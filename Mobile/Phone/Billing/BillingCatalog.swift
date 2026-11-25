import Foundation

/// App 内課金の商品と、購入の画面に出す文書の場所（製品版の P6）。
/// 商品 ID・価格・利用規約とプライバシーポリシーの URL は、App Store Connect の登録と価格・文書を決めるときに決まる（公開の前）。
/// いまの値は仮で、差し替えるのはここだけ。同じ ID をサーバーの src/billing/products.ts（量）と Mobile/PhoneTests/Minutes.storekit（手元の試しの商品）にも書く。
/// 価格・期間・商品名はアプリに書かず、StoreKit の Product（displayName・displayPrice・subscription.subscriptionPeriod）から出す。
enum BillingCatalog {
    /// 月額の Pro（仮）
    static let proMonthly = "jp.pictors.minutes.pro.monthly"

    /// 購入の画面に並べる商品（この順）
    static let productIDs = [proMonthly]

    /// 利用規約（仮。公開の前に決める。自前の規約を作らないなら Apple の標準 EULA: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/ ）
    static let termsURL = URL(string: "https://minutes.tools/terms/")!

    /// プライバシーポリシー（仮。公開の前に決める）
    static let privacyURL = URL(string: "https://minutes.tools/privacy/")!
}
