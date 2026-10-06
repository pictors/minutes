import AppKit
import ImageIO
import SwiftUI

/// 採用済み B1 の原画をそのまま使う。文字とマークは表示時に分け、テーマに合わせて着色する。
@MainActor
enum BrandAssets {
    /// 配布 .app は SwiftPM のリソースバンドルを Contents/Resources に置く。`swift run` では実行ファイルの隣にある。
    /// `Bundle.module` はビルドした Mac の絶対パスに頼り、見つからないと起動時に fatalError するので使わない。
    private static let resourceBundle: Bundle? = {
        let name = "minutes_MinutesApp.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0?.appendingPathComponent(name) }
        return candidates.lazy.compactMap { Bundle(url: $0) }.first
    }()

    private static let source: CGImage? = {
        guard let url = resourceBundle?.url(forResource: "MinutesLogo", withExtension: "png", subdirectory: "Resources/Brand"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    // 1774 × 887 px の採用原画の範囲。輪郭のアンチエイリアスを含む透明な余白も残す。
    static let mark = image(in: CGRect(x: 156, y: 277, width: 354, height: 297))
    static let wordmark = image(in: CGRect(x: 561, y: 303, width: 1065, height: 245))

    static let menuBarMark: NSImage = {
        let image = mark.copy() as! NSImage
        image.size = NSSize(width: 18, height: 18 * mark.size.height / mark.size.width)
        image.isTemplate = true
        return image
    }()

    private static func image(in rect: CGRect) -> NSImage {
        guard let cropped = source?.cropping(to: rect) else {
            // ブランド素材が破損しても録音機能の起動を妨げない。
            return NSImage(systemSymbolName: "waveform", accessibilityDescription: "Minutes") ?? NSImage()
        }
        return NSImage(cgImage: cropped, size: rect.size)
    }
}

struct MinutesBrandLockup: View {
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: height * 0.18) {
            Image(nsImage: BrandAssets.mark)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .foregroundStyle(Palette.periwinkle)
                .frame(width: height * 354 / 297, height: height)
            Image(nsImage: BrandAssets.wordmark)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .foregroundStyle(.primary)
                .frame(width: height * 1065 / 297, height: height * 245 / 297)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minutes")
    }
}
