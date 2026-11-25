import Foundation
import MinutesKit
import Observation
import StoreKit
// PurchaseAction（SwiftUI の購入）は StoreKit の SwiftUI の側にある
import SwiftUI

/// App 内課金（製品版の P6）: StoreKit 2 の商品・購入・復元と、サーバーへの取引の受け渡し。
/// 有料かどうかはサーバーが決める（Apple の署名を根まで確かめる。Mac も同じアカウントで使う）。ここは取引をサーバーへ送り、受け付けられたら終わらせる。
/// - 購入: サーバーの appAccountToken（利用者の ID）を付けて買い、結果の取引をサーバーへ送る
/// - Transaction.updates: 起動してすぐから聞く（自動更新・ほかの端末や App Store での購入・承認待ちだった購入・返金）。ログインしていれば送る
/// - 起動とログインのとき: 終わっていない取引と、いまの権利（currentEntitlements）を送る（取りこぼしの備え。サーバーは同じ取引を重ねない）
/// - 復元: AppStore.sync()（App Store のログインを求める）のあと、いまの権利を送る
/// 取引を終わらせる（finish）のは、サーバーが受け付けたとき（2xx）と、何度送っても受け付けられないとき（4xx。権利は currentEntitlements に
/// 残り、次の起動でも送る）。回線・サーバーの失敗とログインしていないときは終わらせず、次の起動で updates から届き直す。
/// 文書（2026-11-25 に確かめた）: Transaction.updates（起動してすぐ Task で聞く。終わっていない取引は起動の直後に一度届く）・currentEntitlements
/// （購読中と猶予期間の最新の取引。返金・取り消しは入らない）・Transaction.unfinished・Transaction.finish()（中身を渡したあとに呼ぶ）・
/// AppStore.sync()（ログインを求めるので、ボタンを押したときだけ）・Product.PurchaseOption.appAccountToken(_:)・PurchaseAction（SwiftUI の購入）。
@MainActor
@Observable
final class BillingStore {
    /// 画面に出す結果
    struct Message: Equatable, Identifiable {
        enum Kind { case success, info, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    /// 取引をサーバーへ送った結果
    enum Delivery: Equatable {
        case accepted(MinutesCloudBilling)
        /// ほかの Minutes アカウントに結んである
        case otherAccount
        /// 何度送っても受け付けられない（code）
        case rejected(String)
        case notSignedIn
        /// 回線・サーバーの失敗（あとで送り直す）
        case failed(String)
        /// この端末で確かめられない取引・売っていない商品
        case skipped
    }

    private(set) var products: [Product] = []
    private(set) var productsError: String?
    private(set) var isLoadingProducts = false
    private(set) var billing: MinutesCloudBilling?
    /// StoreKit の更新の情報（商品 ID → 自動更新が入っているか）。サーバーが更新の情報をまだ持たないときに使う
    private(set) var willAutoRenew: [String: Bool] = [:]
    /// はじめての割引（お試し）を使えるか（商品 ID → 使える）
    private(set) var introEligible: [String: Bool] = [:]
    private(set) var isWorking = false
    var message: Message?
    /// 有料かどうかが変わったかもしれない（アカウント・一覧を読み直し、断られた送信をやり直す）
    var onChange: (() -> Void)?

    private let client: () -> MinutesCloudClient
    private let isSignedIn: () -> Bool
    private var updatesTask: Task<Void, Never>?

    static let otherAccountText = "この Apple ID の購入は、ほかの Minutes アカウントで使っています。購入したときのアカウントでログインしてください。"

    init(client: @escaping () -> MinutesCloudClient = { CloudEnvironment.client() }, isSignedIn: @escaping () -> Bool = { TokenStore.shared.isSignedIn }) {
        self.client = client
        self.isSignedIn = isSignedIn
    }

    // MARK: 起動・ログイン

    /// Transaction.updates を聞き始める（起動してすぐ。終わっていない取引は、聞き始めた直後に一度届く）。
    func startListening() {
        guard updatesTask == nil else { return }
        updatesTask = Task(priority: .background) { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                await self.deliver(result)
            }
        }
    }

    func stopListening() {
        updatesTask?.cancel()
        updatesTask = nil
    }

    /// ログインしているとき: 終わっていない取引と、いまの権利をサーバーへ送り、サーバーの状態を読む。
    func syncWithServer() async {
        guard isSignedIn() else { return }
        for await result in StoreKit.Transaction.unfinished { await deliver(result) }
        for await result in StoreKit.Transaction.currentEntitlements { await deliver(result) }
        await refreshBilling()
    }

    /// ログアウトしたとき
    func reset() {
        billing = nil
        message = nil
    }

    // MARK: 読む

    func refreshBilling() async {
        guard isSignedIn() else { return }
        if let billing = try? await client().billing() { self.billing = billing }
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: BillingCatalog.productIDs)
            products = BillingCatalog.productIDs.compactMap { id in loaded.first { $0.id == id } }
            productsError = products.isEmpty ? "App Store から商品を読み込めませんでした" : nil
        } catch {
            productsError = "App Store から商品を読み込めませんでした（\(error.localizedDescription)）"
        }
        await refreshRenewalState()
    }

    /// StoreKit の更新の情報（自動更新）と、お試しを使えるか
    func refreshRenewalState() async {
        for product in products {
            guard let subscription = product.subscription else { continue }
            introEligible[product.id] = await subscription.isEligibleForIntroOffer
            guard let statuses = try? await subscription.status else { continue }
            for status in statuses {
                if case let .verified(renewal) = status.renewalInfo, renewal.currentProductID == product.id {
                    willAutoRenew[product.id] = renewal.willAutoRenew
                }
            }
        }
    }

    /// 購入に付ける appAccountToken（サーバーの利用者の ID）。サーバーの状態も読み直す
    func appAccountToken() async throws -> UUID {
        let billing = try await client().billing()
        self.billing = billing
        guard let token = billing.appAccountTokenUUID else { throw MinutesCloudError.invalidResponse("app_account_token が UUID ではない") }
        return token
    }

    // MARK: 送る

    /// 取引をサーバーへ送る。受け付けられた・何度送っても受け付けられないなら、取引を終わらせる。
    @discardableResult
    func deliver(_ result: VerificationResult<StoreKit.Transaction>) async -> Delivery {
        // この端末で確かめられない取引は送らない（サーバーも Apple の根まで確かめる）。終わらせもしない
        guard case let .verified(transaction) = result else { return .skipped }
        guard BillingCatalog.productIDs.contains(transaction.productID) else { return .skipped }
        guard isSignedIn() else { return .notSignedIn }
        do {
            let billing = try await client().submitAppStoreTransaction(signedTransaction: result.jwsRepresentation)
            self.billing = billing
            await transaction.finish()
            onChange?()
            return .accepted(billing)
        } catch let error as MinutesCloudError {
            if error.status == 409, error.code == MinutesCloudBillingError.otherAccount {
                await transaction.finish()
                return .otherAccount
            }
            if (400..<500).contains(error.status ?? 0), error.status != 401 {
                await transaction.finish()
                return .rejected(error.code ?? String(error.status ?? 0))
            }
            return .failed(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: 購入・復元

    /// 画面の「Pro にする」。購入の確認は StoreKit が出す（PurchaseAction）
    func purchase(_ product: Product, with purchase: PurchaseAction) async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            let token = try await appAccountToken()
            let result = try await purchase(product, options: [.appAccountToken(token)])
            await handle(result)
        } catch let error as MinutesCloudError {
            message = Message(kind: .error, text: "購入の準備ができませんでした（\(error.localizedDescription)）")
        } catch {
            message = Message(kind: .error, text: "購入できませんでした（\(error.localizedDescription)）")
        }
    }

    /// 購入の結果を受ける（画面の購入と、テストの購入で同じ道を通る）
    func handle(_ result: Product.PurchaseResult) async {
        switch result {
        case let .success(verification):
            message = Self.message(for: await deliver(verification), purchased: true)
        case .pending:
            message = Message(kind: .info, text: "購入の承認を待っています。承認されると、自動で Pro になります。")
        case .userCancelled:
            message = nil
        @unknown default:
            message = nil
        }
    }

    /// 画面の「購入を復元」
    func restore() async {
        isWorking = true
        defer { isWorking = false }
        message = nil
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            return
        } catch {
            message = Message(kind: .error, text: "App Store と同期できませんでした（\(error.localizedDescription)）")
            return
        }
        var deliveries: [Delivery] = []
        for await result in StoreKit.Transaction.currentEntitlements { deliveries.append(await deliver(result)) }
        await refreshBilling()
        await refreshRenewalState()
        message = Self.restoreMessage(deliveries, billing: billing)
    }

    static func message(for delivery: Delivery, purchased: Bool) -> Message? {
        switch delivery {
        case let .accepted(billing):
            return billing.entitlement.isPro
                ? Message(kind: .success, text: purchased ? "Pro になりました。文字起こしと議事録を使えます。" : "購入を確かめました。")
                : Message(kind: .info, text: "購入を受け付けましたが、有効な期間ではありません。")
        case .otherAccount:
            return Message(kind: .error, text: otherAccountText)
        case let .rejected(code):
            return Message(kind: .error, text: "購入をサーバーで確かめられませんでした（\(code)）。")
        case .notSignedIn:
            return Message(kind: .error, text: "ログインしてから、購入を復元してください。")
        case let .failed(text):
            return Message(kind: .info, text: "購入しました。サーバーに伝えられなかったので、つながったら自動で伝えます（\(text)）。")
        case .skipped:
            return Message(kind: .error, text: "この購入を確かめられませんでした。")
        }
    }

    static func restoreMessage(_ deliveries: [Delivery], billing: MinutesCloudBilling?) -> Message {
        if deliveries.contains(where: { if case .accepted = $0 { true } else { false } }) {
            return billing?.entitlement.isPro == true
                ? Message(kind: .success, text: "購入を復元しました。")
                : Message(kind: .info, text: "購入を復元しましたが、有効な期間ではありません。")
        }
        if deliveries.contains(.otherAccount) { return Message(kind: .error, text: otherAccountText) }
        if let failure = deliveries.lazy.compactMap({ delivery -> String? in if case let .failed(text) = delivery { text } else { nil } }).first {
            return Message(kind: .error, text: "サーバーに伝えられませんでした（\(failure)）。")
        }
        return Message(kind: .info, text: "復元できる購入はありませんでした。")
    }
}
