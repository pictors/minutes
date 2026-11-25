import Foundation

// App 内課金（製品版の P6）のサーバーの答え。iPhone のアプリが StoreKit 2 の取引を送り、サーバーが Apple の署名を確かめて有料かどうかを決める。
// API の形（サーバーの src/billing/routes.ts、2026-11-25）:
//   GET  /v1/billing → {app_account_token, entitlement: {plan, source, expires_at, monthly_seconds_limit}, subscriptions: [...]}
//   POST /v1/billing/app-store/transactions {signed_transaction: <Transaction の jwsRepresentation>} → 同じ形
//        断るとき: 400 invalid_transaction・wrong_app・environment_not_allowed・unsupported_product・unknown_product、409 other_account
// 購入（Product.PurchaseOption.appAccountToken）には app_account_token（利用者の ID）を渡す。サーバーはそれで購入をアカウントに結ぶ。

/// 有料かどうかと、App Store のサブスクリプション。
public struct MinutesCloudBilling: Decodable, Sendable, Equatable {
    public struct Entitlement: Decodable, Sendable, Equatable {
        /// "free" | "pro"（期限を過ぎていれば free）
        public var plan: String
        /// "manual"（手で決めた）| "app_store" | nil（決めたことがない）
        public var source: String?
        /// 使えなくなる日時（App Store なら期限か猶予期間の終わり。手で決めたものは nil のことがある）
        public var expiresAt: Date?
        public var monthlySecondsLimit: Double

        public var isPro: Bool { plan == "pro" }
    }

    public struct Subscription: Decodable, Sendable, Equatable, Identifiable {
        public var originalTransactionId: String
        public var productId: String
        /// "Production" | "Sandbox" | "Xcode"
        public var environment: String
        public var active: Bool
        public var expiresAt: Date?
        public var accessEndsAt: Date?
        /// 自動更新（更新の情報がまだサーバーにないときは nil）
        public var autoRenew: Bool?
        public var inBillingRetry: Bool
        public var gracePeriodExpiresAt: Date?
        public var revoked: Bool

        public var id: String { originalTransactionId }
    }

    /// サーバーが売っている商品と、それぞれの 1 か月の量（サーバーの src/billing/products.ts が正）
    public struct Product: Decodable, Sendable, Equatable {
        public var productId: String
        public var plan: String
        public var monthlySecondsLimit: Double
    }

    /// 購入のときに appAccountToken として渡す UUID（利用者の ID）
    public var appAccountToken: String
    public var entitlement: Entitlement
    public var subscriptions: [Subscription]
    public var products: [Product]?

    public var appAccountTokenUUID: UUID? { UUID(uuidString: appAccountToken) }

    /// 商品の 1 か月の量（秒）。知らない商品なら nil
    public func monthlySecondsLimit(productID: String) -> Double? {
        products?.first { $0.productId == productID }?.monthlySecondsLimit
    }
}

/// App 内課金のサーバーの誤り（MinutesCloudError.http の code）。
public enum MinutesCloudBillingError {
    /// この購入はほかの Minutes アカウントに結んである（サーバーは移さない）
    public static let otherAccount = "other_account"
    /// Apple の署名を確かめられない（壊れている・Apple の鎖でない・手元の開発の署名を本番に送った）
    public static let invalidTransaction = "invalid_transaction"
    public static let environmentNotAllowed = "environment_not_allowed"
    public static let unknownProduct = "unknown_product"
}
