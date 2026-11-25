import Foundation
import MinutesKit
import Synchronization
import Testing

/// App 内課金（P6）のサーバーとのやり取り。値は架空。
@Suite("Minutes クラウドの App 内課金")
struct MinutesCloudBillingTests {
    private static func reply(_ object: Any, status: Int = 200) -> (status: Int, headers: [String: String], body: Data) {
        (status, ["content-type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    /// 架空の利用者の ID
    private static let fictionalUserID = "6f1b2c4e-0000-4000-8000-00000000abcd"

    private static var proBilling: [String: Any] { [
        "app_account_token": fictionalUserID,
        "entitlement": ["plan": "pro", "source": "app_store", "expires_at": "2026-12-25T03:00:00.000Z", "monthly_seconds_limit": 10800, "trial": true],
        "products": [
            ["product_id": "jp.pictors.minutes.pro.monthly", "plan": "pro", "monthly_seconds_limit": 72000, "trial_seconds_limit": 10800],
            ["product_id": "jp.pictors.minutes.pro.yearly", "plan": "pro", "monthly_seconds_limit": 72000, "trial_seconds_limit": 10800],
        ],
        "subscriptions": [[
            "original_transaction_id": "2000000000000001",
            "product_id": "jp.pictors.minutes.pro.monthly",
            "environment": "Sandbox",
            "active": true,
            "expires_at": "2026-12-25T03:00:00.000Z",
            "access_ends_at": "2026-12-25T03:00:00.000Z",
            "auto_renew": NSNull(),
            "in_billing_retry": false,
            "grace_period_expires_at": NSNull(),
            "revoked": false,
        ]],
    ] }

    @Test("取引の JWS を送り、有料かどうかと appAccountToken を読む（ミリ秒つきの日時・値のない欄）")
    func submit() async throws {
        let received = Mutex<[String: Any]>([:])
        let base = StubURLProtocol.host { request in
            guard request.method == "POST", request.path == "/v1/billing/app-store/transactions" else { return Self.reply(["error": "not_found"], status: 404) }
            received.withLock { $0 = (request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:] }
            return Self.reply(Self.proBilling)
        }
        let billing = try await MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" })
            .submitAppStoreTransaction(signedTransaction: "header.payload.signature")
        #expect(received.withLock { $0["signed_transaction"] as? String } == "header.payload.signature")
        #expect(billing.entitlement.isPro && billing.entitlement.source == "app_store" && billing.entitlement.monthlySecondsLimit == 10800 && billing.entitlement.trial == true)
        #expect(billing.monthlySecondsLimit(productID: "jp.pictors.minutes.pro.yearly") == 72000 && billing.trialSecondsLimit(productID: "jp.pictors.minutes.pro.monthly") == 10800)
        #expect(billing.monthlySecondsLimit(productID: "jp.example.unknown") == nil)
        #expect(billing.entitlement.expiresAt == JSONCoding.parseISO8601("2026-12-25T03:00:00Z"))
        #expect(billing.appAccountTokenUUID == UUID(uuidString: "6F1B2C4E-0000-4000-8000-00000000ABCD"))
        let subscription = try #require(billing.subscriptions.first)
        #expect(subscription.active && subscription.autoRenew == nil && !subscription.revoked && subscription.id == "2000000000000001")
    }

    @Test("ほかのアカウントに結んだ購入は 409 other_account")
    func otherAccount() async throws {
        let base = StubURLProtocol.host { _ in Self.reply(["error": "other_account"], status: 409) }
        await #expect(throws: MinutesCloudError.http(status: 409, code: MinutesCloudBillingError.otherAccount, requestID: nil)) {
            try await MinutesCloudClient(baseURL: base, session: StubURLProtocol.session(), token: { "fictional-token" }).submitAppStoreTransaction(signedTransaction: "a.b.c")
        }
    }

    @Test("GET /v1/me の有料の出どころと期限（前のサーバーは送らない）")
    func accountPlanDetails() async throws {
        let withDetails = StubURLProtocol.host { _ in
            Self.reply(["user": ["id": "u1"], "plan": "pro",
                        "usage": ["seconds_this_month": 0, "seconds_pending": 0, "seconds_limit": 72000,
                                  "period_start": "2026-11-25T03:00:00.000Z", "period_end": "2026-12-25T03:00:00.000Z"],
                        "plan_source": "app_store", "plan_expires_at": "2026-12-25T03:00:00.000Z"])
        }
        let account = try await MinutesCloudClient(baseURL: withDetails, session: StubURLProtocol.session(), token: { "t" }).account()
        #expect(account.planSource == "app_store" && account.planExpiresAt == JSONCoding.parseISO8601("2026-12-25T03:00:00Z"))
        #expect(account.usage.periodStart == JSONCoding.parseISO8601("2026-11-25T03:00:00Z") && account.usage.periodEnd == JSONCoding.parseISO8601("2026-12-25T03:00:00Z"))
        let older = StubURLProtocol.host { _ in Self.reply(["user": ["id": "u1"], "plan": "free", "usage": ["seconds_this_month": 0, "seconds_pending": 0, "seconds_limit": 0]]) }
        let previous = try await MinutesCloudClient(baseURL: older, session: StubURLProtocol.session(), token: { "t" }).account()
        #expect(previous.planSource == nil && previous.planExpiresAt == nil && previous.usage.periodEnd == nil)
    }
}
