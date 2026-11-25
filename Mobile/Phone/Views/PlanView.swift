import MinutesKit
import StoreKit
import SwiftUI

/// プラン（製品版の P6）: いまのプラン、Pro の購入、購入の復元、契約の管理。
/// 自動更新のサブスクリプションに要る表示（Apple Developer Program License Agreement の Schedule 2 §3.8(b)、App Review Guidelines 3.1.2(c)。
/// 2026-11-25 に確かめた）: サブスクリプションの名前・期間・価格（と単位あたりの価格）を、買う前にはっきり出す。利用規約とプライバシーポリシーへの
/// リンクをアプリの中に置く。何が使えるか（量）も買う前に書く。名前・期間・価格は StoreKit の Product から出し、量はサーバー（/v1/billing の products）から出す。
/// 購入の復元（3.1.1）と、契約の管理（App Store のサブスクリプションの画面）も置く。
struct PlanView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.purchase) private var purchase
    @State private var managing = false

    private var billing: BillingStore { model.billing }
    private var entitlement: MinutesCloudBilling.Entitlement? { billing.billing?.entitlement }
    private var isPro: Bool { entitlement?.isPro ?? (model.account?.plan == "pro") }
    private var subscription: MinutesCloudBilling.Subscription? { billing.billing?.subscriptions.first { $0.active } ?? billing.billing?.subscriptions.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                if let message = billing.message { messageCard(message) }
                if !isPro || entitlement?.source == "app_store" {
                    ForEach(billing.products, id: \.id) { product in offerCard(product) }
                    if billing.products.isEmpty { productsPlaceholder }
                }
                actionsCard
                legalFooter
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .animation(Motion.layout, value: billing.message)
        }
        .background(Surface.page.ignoresSafeArea())
        .navigationTitle("プラン")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(billing.isWorking)
        .overlay { if billing.isWorking { ProgressView().controlSize(.large) } }
        .manageSubscriptionsSheet(isPresented: $managing)
        .task {
            await billing.loadProducts()
            await billing.refreshBilling()
        }
        .onChange(of: managing) { _, open in
            // 契約の画面を閉じたら、サーバーと StoreKit の状態を読み直す（自動更新の切り替えなど）
            if !open { Task { await billing.syncWithServer(); await billing.refreshRenewalState() } }
        }
    }

    // MARK: いまのプラン

    private var statusCard: some View {
        SectionCard("いまのプラン", systemImage: isPro ? "star.fill" : "person.crop.circle", tint: isPro ? Palette.amber : Palette.periwinkle) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(isPro ? "Pro" : "無料").font(.title2.weight(.bold))
                    if isPro, let limit = entitlement?.monthlySecondsLimit ?? model.account?.usage.secondsLimit, limit > 0 {
                        InfoChip(text: "月 \(Self.hours(limit))", systemImage: "waveform")
                    }
                    Spacer(minLength: 0)
                }
                ForEach(statusLines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusLines: [String] {
        guard isPro else {
            return ["録音・一覧・再生・削除は無料で使えます。文字起こしと議事録（Minutes クラウド）は Pro で使えます。"]
        }
        if entitlement?.source == "manual" {
            if let end = entitlement?.expiresAt { return ["\(Self.date(end))まで使えます（手で設定したプラン）。"] }
            return ["手で設定したプランです。"]
        }
        guard let subscription else { return [] }
        var lines: [String] = []
        if subscription.inBillingRetry, let grace = subscription.gracePeriodExpiresAt, grace > Date() {
            lines.append("支払いに問題があります。\(Self.date(grace))までは使えます。App Store のお支払い方法を確かめてください。")
        } else if let end = subscription.expiresAt {
            let autoRenew = subscription.autoRenew ?? billing.willAutoRenew[subscription.productId]
            switch autoRenew {
            case .some(false): lines.append("\(Self.date(end))まで使えます（自動更新はオフ）。")
            case .some(true): lines.append("次の更新は\(Self.date(end))です。")
            case .none: lines.append("いまの期間は\(Self.date(end))までです。")
            }
        }
        if subscription.environment != "Production" { lines.append("テストの購入です（\(subscription.environment)）。") }
        return lines
    }

    // MARK: 商品

    private func offerCard(_ product: Product) -> some View {
        let period = product.subscription.map { Self.period($0.subscriptionPeriod) }
        let limit = billing.billing?.monthlySecondsLimit(productID: product.id)
        let owned = subscription?.productId == product.id && isPro
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(product.displayName).font(.headline)
                Spacer(minLength: 8)
                if owned { InfoChip(text: "契約中", systemImage: "checkmark") }
            }
            if !product.description.isEmpty {
                Text(product.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let limit { bullet("文字起こしと議事録を、1 か月に \(Self.hours(limit))まで") }
                bullet("iPhone・Apple Watch・Mac で、同じアカウントで使えます")
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(product.displayPrice).font(.title3.weight(.bold)).monospacedDigit()
                if let period { Text("/ \(period.unit)").foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                if let period { Text("\(period.length)ごとの自動更新").font(.caption).foregroundStyle(.secondary) }
            }
            if let offer = introOfferText(product) {
                Text(offer).font(.footnote.weight(.medium)).foregroundStyle(Palette.mint)
            }
            if !owned {
                Button {
                    Task { await billing.purchase(product, with: purchase) }
                } label: {
                    Text(isPro ? "このプランにする" : "Pro にする")
                }
                .buttonStyle(FilledPillButtonStyle())
                .disabled(!model.isSignedIn)
                .accessibilityIdentifier("plan.purchase.\(product.id)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var productsPlaceholder: some View {
        HStack(spacing: 10) {
            if billing.isLoadingProducts { ProgressView() }
            Text(billing.isLoadingProducts ? "商品を読み込んでいます" : (billing.productsError ?? "商品を読み込めませんでした"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func bullet(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.periwinkle)
        }
        .font(.subheadline)
    }

    private func introOfferText(_ product: Product) -> String? {
        guard let offer = product.subscription?.introductoryOffer, billing.introEligible[product.id] == true else { return nil }
        let period = Self.period(offer.period)
        switch offer.paymentMode {
        case .freeTrial: return "最初の\(period.length)は無料。その後 \(product.displayPrice) / \(Self.period(product.subscription!.subscriptionPeriod).unit)"
        case .payUpFront: return "最初の\(period.length)は \(offer.displayPrice)"
        case .payAsYouGo: return "最初の \(offer.periodCount) \(period.unit)は \(offer.displayPrice) / \(period.unit)"
        default: return nil
        }
    }

    // MARK: 復元・管理

    private var actionsCard: some View {
        VStack(spacing: 0) {
            Button {
                Task { await billing.restore() }
            } label: {
                row("購入を復元", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("plan.restore")
            Rectangle().fill(Surface.hairline).frame(height: 1).padding(.leading, 52)
            Button {
                managing = true
            } label: {
                row("契約を管理（解約・自動更新）", systemImage: "creditcard")
            }
        }
        .buttonStyle(CardPressStyle())
        .cardBackground()
        .disabled(!model.isSignedIn)
    }

    private func row(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 24)
            Text(title)
            Spacer()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 54)
        .contentShape(.rect)
    }

    private func messageCard(_ message: BillingStore.Message) -> some View {
        let tint: Color = switch message.kind {
        case .success: Palette.mint
        case .info: Palette.cyan
        case .error: Palette.rose
        }
        let symbol = switch message.kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
        return Label(message.text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .accessibilityIdentifier("plan.message")
    }

    // MARK: 規約

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("お支払いは、購入を確かめたときに Apple アカウントに請求されます。サブスクリプションは、期間の終わりの 24 時間前までに自動更新を切らない限り、同じ期間・同じ価格で自動的に更新されます。解約と自動更新の切り替えは、「契約を管理」（App Store のアカウントの設定）からできます。")
            Text("Minutes のアカウントを消しても、App Store のサブスクリプションは止まりません。先に解約してください。")
            HStack(spacing: 16) {
                Link("利用規約", destination: BillingCatalog.termsURL)
                Link("プライバシーポリシー", destination: BillingCatalog.privacyURL)
            }
            .font(.footnote.weight(.medium))
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
    }

    // MARK: 書き方

    /// 108000 → 「30時間」、5400 → 「1時間30分」
    static func hours(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)分" }
        return minutes % 60 == 0 ? "\(minutes / 60)時間" : "\(minutes / 60)時間\(minutes % 60)分"
    }

    /// 12月25日（木）
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
    }

    /// 期間の書き方: unit は「/ 月」の「月」、length は「1か月」
    static func period(_ period: Product.SubscriptionPeriod) -> (unit: String, length: String) {
        let n = period.value
        switch period.unit {
        case .day: return (n == 1 ? "日" : "\(n)日", "\(n)日")
        case .week: return (n == 1 ? "週" : "\(n)週", "\(n)週間")
        case .month: return (n == 1 ? "月" : "\(n)か月", "\(n)か月")
        case .year: return (n == 1 ? "年" : "\(n)年", "\(n)年")
        @unknown default: return ("期間", "期間")
        }
    }
}
