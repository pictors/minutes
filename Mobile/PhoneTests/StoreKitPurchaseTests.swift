import CryptoKit
import MinutesKit
import StoreKit
import StoreKitTest
import UIKit
import XCTest
@testable import Minutes

/// App 内課金（製品版の P6）を、StoreKit Testing in Xcode（SKTestSession と Mobile/PhoneTests/Minutes.storekit の仮の商品）で通す。
/// アプリの BillingStore で買い・返金を受け・復元し、手元のサーバーの有料かどうかが変わることを確かめる（サーバーが Xcode の署名を確かめる）。
/// 手元のサーバー（scripts/local-e2e.mjs を E2E_SERVE・E2E_SERVE_PLAN=free・E2E_XCODE_CERT_SHA256 で開いたもの）がないときは飛ばす。
/// 走らせ方は AGENTS.md（TEST_RUNNER_MINUTES_CLOUD_BASE_URL・TEST_RUNNER_MINUTES_CLOUD_TOKEN を付けて xcodebuild test）。
/// テストの中では、アプリ（PhoneModel）は取引を聞かない（このテストの BillingStore だけが送る）。
@MainActor
final class StoreKitPurchaseTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[CloudEnvironment.baseURLEnvName] != nil, environment[TokenStore.tokenEnvName] != nil else {
            throw XCTSkip("手元のサーバー（MINUTES_CLOUD_BASE_URL・MINUTES_CLOUD_TOKEN）がない")
        }
        // Mobile/PhoneTests/Minutes.storekit（このテストの束に入る。アプリには入れない）
        session = try SKTestSession(configurationFileNamed: "Minutes")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session?.clearTransactions()
    }

    func testPurchaseRefundAndRestore() async throws {
        let store = BillingStore()
        let client = CloudEnvironment.client()
        let start = try await client.billing()
        XCTAssertEqual(start.entitlement.plan, "free", "無料の利用者で始める（E2E_SERVE_PLAN=free）")

        // 試しの設定が効くまで少しかかることがある
        var products: [Product] = []
        for _ in 0..<20 where products.isEmpty {
            products = try await Product.products(for: [BillingCatalog.proMonthly])
            if products.isEmpty { try await Task.sleep(for: .milliseconds(500)) }
        }
        print("[storekit] bundled=\(Bundle(for: Self.self).url(forResource: "Minutes", withExtension: "storekit")?.lastPathComponent ?? "なし") storefront=\(session.storefront) locale=\(session.locale.identifier) products=\(products.count)")
        let product = try XCTUnwrap(products.first, "仮の商品を読めない")
        XCTAssertEqual(product.displayName, "Minutes Pro 月額")
        XCTAssertEqual(product.subscription?.subscriptionPeriod.unit, .month)

        // 0. 無料のまま上げた録音は、処理を頼むと 402（使える量 0）で断られる
        let pending = try await uploadRecording(client, title: "架空の課金の確かめ")
        do {
            _ = try await client.complete(recordingID: pending, durationSeconds: 2)
            XCTFail("無料なのに処理を頼めた")
        } catch let error as MinutesCloudError {
            XCTAssertEqual(error.status, 402)
            XCTAssertEqual(error.code, "limit_exceeded")
        }

        // 1. 買う（appAccountToken = サーバーの利用者の ID）→ サーバーが Xcode の署名を確かめて pro
        let token = try await store.appAccountToken()
        XCTAssertEqual(token.uuidString.lowercased(), start.appAccountToken)
        let result = try await product.purchase(confirmIn: try Self.scene(), options: [.appAccountToken(token)])
        guard case let .success(verification) = result else { return XCTFail("買えない: \(result)") }
        Self.describe(verification)
        guard case let .verified(transaction) = verification else { return XCTFail("StoreKit が確かめられない取引") }
        XCTAssertEqual(transaction.appAccountToken, token)
        await store.handle(result)
        XCTAssertEqual(store.message?.kind, .success, store.message?.text ?? "知らせなし")
        let purchased = try await client.billing()
        XCTAssertEqual(purchased.entitlement.plan, "pro")
        // 試しの商品には 7 日の無料の試用があるので、最初の購入は試用（使えるのは合計 3 時間）
        XCTAssertEqual(purchased.entitlement.trial, true)
        XCTAssertEqual(purchased.entitlement.monthlySecondsLimit, purchased.trialSecondsLimit(productID: BillingCatalog.proMonthly))
        XCTAssertEqual(purchased.entitlement.source, "app_store")
        XCTAssertEqual(purchased.subscriptions.first?.environment, "Xcode")
        XCTAssertEqual(purchased.subscriptions.first?.productId, BillingCatalog.proMonthly)
        let account = try await client.account()
        XCTAssertEqual(account.plan, "pro")
        XCTAssertGreaterThan(account.usage.secondsLimit, 0)
        XCTAssertEqual(account.planSource, "app_store")
        XCTAssertNotNil(account.usage.periodEnd)

        // 1'. 断られていた録音の処理を頼み直すと、キーなしの文字起こしと要約までできる（アプリは購入のあと送信をやり直す）
        _ = try await client.complete(recordingID: pending, durationSeconds: 2)
        let done = try await waitForStatus(pending, client: client)
        XCTAssertEqual(done.status, "done")
        let summary = try await client.summary(recordingID: pending)
        XCTAssertFalse(summary.summaryMd.isEmpty, "要約がない")
        _ = try await client.transcript(recordingID: pending)

        // 2. 返金（App Store の外で）→ Transaction.updates に取り消された取引が届き、アプリが送る → free
        store.startListening()
        let refunded = try XCTUnwrap(session.allTransactions().last { $0.productIdentifier == BillingCatalog.proMonthly })
        try session.refundTransaction(identifier: refunded.identifier)
        try await waitForPlan("free", client: client)
        store.stopListening()
        let afterRefund = try await uploadRecording(client, title: "架空の返金のあと")
        do {
            _ = try await client.complete(recordingID: afterRefund, durationSeconds: 2)
            XCTFail("返金のあとなのに処理を頼めた")
        } catch let error as MinutesCloudError {
            XCTAssertEqual(error.status, 402)
        }

        // 3. アプリが聞いていないあいだの、App Store の外での購入（ほかの端末・App Store。appAccountToken なし）→ サーバーは知らないので free のまま。
        //    「購入を復元」（AppStore.sync のあと currentEntitlements を送る）で pro
        _ = try await session.buyProduct(identifier: BillingCatalog.proMonthly, options: [])
        try await Task.sleep(for: .seconds(2))
        let beforeRestore = try await client.billing()
        XCTAssertEqual(beforeRestore.entitlement.plan, "free", "聞いていないので、まだ送っていない")
        await store.restore()
        XCTAssertEqual(store.message?.kind, .success, store.message?.text ?? "知らせなし")
        let restored = try await client.billing()
        XCTAssertEqual(restored.entitlement.plan, "pro")
    }

    /// iPhone の録音を作って音声を上げる（中身は架空。手元のサーバーの偽の ElevenLabs は中身を読まない）。録音の ID を返す
    private func uploadRecording(_ client: MinutesCloudClient, title: String) async throws -> String {
        let recording = try await client.createRecording(
            MinutesCloudRecordingRequest(clientId: "storekit-test-\(UUID().uuidString)", source: "iphone", title: title, contentType: "audio/aac", summarize: true)
        )
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(recording.id).aac")
        try Data(repeating: 0x5A, count: 8000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await client.uploadAudio(recordingID: recording.id, fileURL: file, contentType: "audio/aac")
        return recording.id
    }

    private func waitForStatus(_ id: String, client: MinutesCloudClient, timeout: Duration = .seconds(60)) async throws -> MinutesCloudRecording {
        let deadline = ContinuousClock.now + timeout
        var recording = try await client.recording(id: id)
        while ContinuousClock.now < deadline, !["done", "failed"].contains(recording.status) {
            try await Task.sleep(for: .milliseconds(500))
            recording = try await client.recording(id: id)
        }
        return recording
    }

    private func waitForPlan(_ plan: String, client: MinutesCloudClient, timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await client.billing().entitlement.plan == plan { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("\(timeout) たっても \(plan) にならない")
    }

    private static func scene() throws -> UIScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first, "画面がない")
    }

    /// Xcode の署名の形を出す（手元のサーバーに受けさせる証明書の指紋 E2E_XCODE_CERT_SHA256 を決めるため。公開の試しの証明書で、秘密ではない）
    private static func describe(_ verification: VerificationResult<Transaction>) {
        let parts = verification.jwsRepresentation.split(separator: ".")
        guard parts.count == 3, let header = decode(String(parts[0])), let payload = decode(String(parts[1])) else {
            print("[storekit] JWS を読めない")
            return
        }
        let chain = (header["x5c"] as? [String]) ?? []
        let fingerprints = chain.compactMap { Data(base64Encoded: $0) }.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        print("[storekit] alg=\(header["alg"] ?? "-") x5c=\(chain.count) environment=\(payload["environment"] ?? "-") sha256=\(fingerprints.joined(separator: ","))")
    }

    private static func decode(_ part: String) -> [String: Any]? {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
