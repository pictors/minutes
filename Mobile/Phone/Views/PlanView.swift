import MinutesKit
import StoreKit
import SwiftUI

/// プラン（製品版の P6）: いまのプラン、Pro の購入、購入の復元、契約の管理。
/// 自動更新のサブスクリプションに要る表示（Apple Developer Program License Agreement の Schedule 2 §3.8(b)、App Review Guidelines 3.1.2(c)。
/// 2026-11-25 に確かめた）: サブスクリプションの名前・期間・価格（と単位あたりの価格）を、買う前にはっきり出す。利用規約とプライバシーポリシーへの
/// リンクをアプリの中に置く。何が使えるか（量）も買う前に書く。名前・期間・価格は StoreKit の Product から出し、量はサーバー（/v1/billing の products）から出す。
/// 購入の復元（3.1.1）と、契約の管理（App Store のサブスクリプションの画面）も置く。
/// 商品は「月額｜年額」の切り替えとカード 1 枚で出す: 機能の説明は 1 回だけにし、切り替えで名前・値段・期間・ボタンを替える。
/// 最初に選んでおくのは、契約中の商品か月額（試用のあとに年額が請求されて驚く人を出さない）。年額には何か月分お得かを添え、
/// 月あたりの額は請求される額より小さく出す（3.1.2(c)）。購入のあと、無料から Pro になったら演出を出す（ProCelebrationView）。
struct PlanView: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.purchase) private var purchase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var managing = false
    /// 切り替えで選んだ商品（押すまでは nil: 契約中の商品か月額を出す）
    @State private var chosenProductID: String?
    /// 紙吹雪を降らせた購入（カードを閉じても、降っている紙吹雪は最後まで落とす）
    @State private var confettiTrigger: UUID?

    private var billing: BillingStore { model.billing }
    private var entitlement: MinutesCloudBilling.Entitlement? { billing.billing?.entitlement }
    private var isPro: Bool { entitlement?.isPro ?? (model.account?.plan == "pro") }
    private var subscription: MinutesCloudBilling.Subscription? { billing.billing?.subscriptions.first { $0.active } ?? billing.billing?.subscriptions.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusCard
                // 演出のカードを出しているあいだは、同じ「Pro になりました」の知らせを重ねない
                if let message = billing.message, billing.celebration == nil { messageCard(message) }
                if !isPro || entitlement?.source == "app_store" {
                    if let product = selectedProduct {
                        if billing.products.count > 1 { periodPicker }
                        offerCard(product)
                    } else {
                        productsPlaceholder
                    }
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
        // 演出は .disabled の外に重ねる（カードはタップで閉じる）
        .overlay {
            ZStack {
                if let celebration = billing.celebration {
                    // 画面のカードと同じ左右の余白にする（後ろのカードの端がのぞかない）
                    ProCelebrationCard(celebration: celebration) { dismissCelebration() }
                        .padding(.horizontal, 16)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.88)), removal: .opacity.combined(with: .scale(scale: 0.96))))
                }
            }
            .animation(reduceMotion ? Motion.layout : Motion.pop, value: billing.celebration?.id)
        }
        // 紙吹雪はカードの上に降らせる（後ろだとカードに隠れる）。触れても下（カード・画面）に届く
        .overlay {
            if let confettiTrigger, !reduceMotion {
                ConfettiView(trigger: confettiTrigger)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .sensoryFeedback(.success, trigger: billing.celebration?.id) { _, id in id != nil }
        .onChange(of: billing.celebration?.id) { _, id in
            if let id { confettiTrigger = id }
        }
        .onDisappear { dismissCelebration() }
        .manageSubscriptionsSheet(isPresented: $managing)
        .task {
            // StoreKit の商品と、サーバーの量（1 か月の量・試用の量）を並べて読む（StoreKit が遅くても量を待たせない）
            async let products: Void = billing.loadProducts()
            async let server: Void = billing.refreshBilling()
            _ = await (products, server)
        }
        .onChange(of: managing) { _, open in
            // 契約の画面を閉じたら、サーバーと StoreKit の状態を読み直す（自動更新の切り替えなど）
            if !open { Task { await billing.syncWithServer(); await billing.refreshRenewalState() } }
        }
    }

    /// 購入のあとの演出を閉じる。演出で伝えたので、同じ「Pro になりました」の知らせは残さない
    private func dismissCelebration() {
        guard billing.celebration != nil else { return }
        billing.celebration = nil
        if billing.message?.kind == .success { billing.message = nil }
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
        if billing.billing?.entitlement.trial == true, let limit = entitlement?.monthlySecondsLimit {
            lines.append("無料の試用中です（試用のあいだに使えるのは、合計 \(Self.hours(limit))まで）。")
        }
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

    /// 契約中の商品（App Store で Pro のとき）
    private var ownedProductID: String? {
        guard isPro, entitlement?.source == "app_store", let id = subscription?.productId, billing.products.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// カードに出す商品: 押して選んだもの、なければ契約中の商品、なければ月額（いちばん前の商品）
    private var selectedProduct: Product? {
        let products = billing.products
        let id = chosenProductID ?? ownedProductID ?? BillingCatalog.proMonthly
        return products.first { $0.id == id } ?? products.first
    }

    private func owned(_ product: Product) -> Bool {
        subscription?.productId == product.id && isPro
    }

    /// 「月額｜年額」の切り替え（SegmentedTabs。年額には何か月分お得かを添える。月額を選んでいるときも見える）
    private var periodPicker: some View {
        SegmentedTabs(
            tabs: billing.products.map(\.id),
            selection: Binding(
                get: { selectedProduct?.id ?? BillingCatalog.proMonthly },
                set: { id in if id != selectedProduct?.id { chosenProductID = id } }
            ),
            title: { id in billing.products.first { $0.id == id }.map(Self.periodTitle) ?? id },
            badge: { id in billing.products.first { $0.id == id }.flatMap(savingsMonths).map { "\($0) か月分お得" } }
        )
        .sensoryFeedback(.selection, trigger: chosenProductID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("支払いの間隔")
    }

    /// 商品のカード（1 枚）。機能の説明は切り替えで変わらず、名前・値段・期間・試用・ボタンが変わる
    private func offerCard(_ product: Product) -> some View {
        let limit = billing.billing?.monthlySecondsLimit(productID: product.id)
        let owned = owned(product)
        return VStack(alignment: .leading, spacing: 14) {
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
            priceBlock(product)
            if !owned, let offer = introOfferText(product) {
                Text(offer)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.mint)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
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

    /// 値段。請求される額（¥19,800 / 年）をいちばん大きく、月あたりの額と更新の間隔は小さく添える（3.1.2(c)）
    private func priceBlock(_ product: Product) -> some View {
        let period = product.subscription.map { Self.period($0.subscriptionPeriod) }
        let details = [monthlyEquivalent(product).map { "月あたり \($0)" }, period.map { "\($0.length)ごとの自動更新" }].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(product.displayPrice)
                    .font(.system(size: 32, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let period {
                    Text("/ \(period.unit)")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if !details.isEmpty {
                Text(details.joined(separator: "・"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
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
        case .freeTrial:
            let cap = billing.billing?.trialSecondsLimit(productID: product.id).map { "（試用のあいだは合計 \(Self.hours($0))まで）" } ?? ""
            return "最初の \(period.length)は無料\(cap)。その後 \(product.displayPrice) / \(Self.period(product.subscription!.subscriptionPeriod).unit)"
        case .payUpFront: return "最初の \(period.length)は \(offer.displayPrice)"
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

    /// 108000 → 「30 時間」、5400 → 「1 時間 30 分」（数字と単位のあいだは空ける）
    static func hours(_ seconds: Double) -> String {
        Formatting.duration(seconds)
    }

    /// 12月25日（木）
    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day().weekday(.abbreviated).locale(Locale(identifier: "ja_JP")))
    }

    /// 切り替えの名前: 1 か月なら「月額」、1 年なら「年額」（ほかは「3 か月ごと」など）
    static func periodTitle(_ product: Product) -> String {
        guard let period = product.subscription?.subscriptionPeriod else { return product.displayName }
        switch (period.unit, period.value) {
        case (.month, 1): return "月額"
        case (.year, 1): return "年額"
        default: return "\(Self.period(period).length)ごと"
        }
    }

    /// 1 年の商品が、1 か月の商品の 12 か月より何か月分安いか（端数は切り捨て。1 か月に満たない・通貨が違う・比べる商品がないときは nil）
    private func savingsMonths(_ product: Product) -> Int? {
        guard let period = product.subscription?.subscriptionPeriod, period.unit == .year, period.value == 1,
              let monthly = billing.products.first(where: { $0.subscription?.subscriptionPeriod.unit == .month && $0.subscription?.subscriptionPeriod.value == 1 }),
              monthly.priceFormatStyle.currencyCode == product.priceFormatStyle.currencyCode, monthly.price > 0
        else { return nil }
        var saved = (monthly.price * 12 - product.price) / monthly.price
        var months = Decimal()
        NSDecimalRound(&months, &saved, 0, .down)
        let value = NSDecimalNumber(decimal: months).intValue
        return value >= 1 ? value : nil
    }

    /// 1 年の商品の月あたりの額（¥1,650）。1 年の商品でなければ nil
    private func monthlyEquivalent(_ product: Product) -> String? {
        guard let period = product.subscription?.subscriptionPeriod, period.unit == .year, period.value == 1 else { return nil }
        return (product.price / 12).formatted(product.priceFormatStyle)
    }

    /// 期間の書き方: unit は「/ 月」の「月」、length は「1 か月」（数字と単位のあいだは空ける）
    static func period(_ period: Product.SubscriptionPeriod) -> (unit: String, length: String) {
        let n = period.value
        switch period.unit {
        case .day: return (n == 1 ? "日" : "\(n) 日", "\(n) 日")
        case .week: return (n == 1 ? "週" : "\(n) 週", "\(n) 週間")
        case .month: return (n == 1 ? "月" : "\(n) か月", "\(n) か月")
        case .year: return (n == 1 ? "年" : "\(n) 年", "\(n) 年")
        @unknown default: return ("期間", "期間")
        }
    }
}
