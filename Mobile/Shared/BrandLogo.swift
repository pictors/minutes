import SwiftUI

// Minutes のロゴの表示（マーク、マーク + 小文字の「minutes」）。Mac の MinutesBrandLockup と同じ組み。
// 輪郭そのもの（BrandLogo・BrandShape）は Mobile/Brand/BrandGeometry.swift（ウィジェットの拡張とも共有する）。

/// マークだけ（ブランドの色）。
struct MinutesMark: View {
    var height: CGFloat = 28
    var color: Color = Palette.periwinkle

    var body: some View {
        BrandShape(part: .mark)
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: height * BrandLogo.markBounds.width / BrandLogo.markBounds.height, height: height)
            .accessibilityHidden(true)
    }
}

/// マーク + 小文字の「minutes」（Mac の MinutesBrandLockup と同じ組み）。height はマークの高さ。
struct MinutesBrandLockup: View {
    var height: CGFloat = 24

    var body: some View {
        let wordHeight = height * BrandLogo.wordmarkBounds.height / BrandLogo.markBounds.height
        HStack(alignment: .center, spacing: height * 0.2) {
            MinutesMark(height: height)
            BrandShape(part: .wordmark)
                .fill(Color.primary, style: FillStyle(eoFill: true))
                .frame(width: wordHeight * BrandLogo.wordmarkBounds.width / BrandLogo.wordmarkBounds.height, height: wordHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minutes")
    }
}
