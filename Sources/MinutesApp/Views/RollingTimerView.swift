import AppKit
import QuartzCore

/// `BigTimerText` の中身。1 文字ずつの層を並べ、変わった桁だけを転がす。数字は CoreText で一度だけ描いて使い回す。
final class RollingTimerView: NSView {
    /// 幅に入らないときに試す大きさ（`size` に対する比）。
    static let fittingScales: [CGFloat] = [1, 0.92, 0.84, 0.76]

    enum Role: Hashable { case primary, secondary, tertiary }

    struct Piece: Hashable {
        var character: Character
        var role: Role
        var isSmall: Bool
    }

    struct Cell {
        var piece: Piece
        var x: CGFloat
        /// この文字を含む段（`Text` 1 つぶん）の始まり。段の始まりは画素にそろえる（SwiftUI の `Text` と同じ）
        var runX: CGFloat
    }

    struct Layout {
        var cells: [Cell]
        var width: CGFloat
        var scale: CGFloat
    }

    /// 親（SwiftUI）が示した幅。大きさの段はこれで選ぶ（自分の幅で選ぶと、桁が増えた瞬間に小さい段を選んでしまう）
    var availableWidth: CGFloat?
    private var seconds: Int?
    private var size: CGFloat = 50
    private var isDimmed = false
    private var current: Layout?
    /// `current.cells` と同じ並びの層
    private var layers: [CALayer] = []
    private var glyphs: [GlyphKey: Glyph] = [:]

    private struct GlyphKey: Hashable {
        var piece: Piece
        var fontSize: CGFloat
        var kern: CGFloat
        var backingScale: CGFloat
        var isDark: Bool
        /// 画素未満の横のずれ（1/8 画素単位）。文字を画像の中でずらして描き、層は画素にそろえて置く（拡大縮小でぼやけさせない）
        var subpixel: Int
    }

    private struct Glyph {
        var image: CGImage
        /// 画像の大きさ（ポイント）と、その中の基準線の高さ・左の余白。ぼかしがはみ出さないよう余白を付けている
        var size: CGSize
        var baseline: CGFloat
        var padding: CGFloat
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 文字の組み方（SwiftUI の HStack(alignment: .firstTextBaseline, spacing: 0) と同じ）

    static func font(size: CGFloat) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .semibold) }

    static func lineHeight(size: CGFloat) -> CGFloat {
        let font = font(size: size)
        return font.ascender - font.descender + font.leading
    }

    private static func runs(seconds: Int, isDimmed: Bool) -> [(text: String, role: Role, isSmall: Bool, leading: CGFloat, trailing: CGFloat)] {
        let main: Role = isDimmed ? .tertiary : .primary
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        var runs: [(text: String, role: Role, isSmall: Bool, leading: CGFloat, trailing: CGFloat)] = [
            (hours > 0 ? "\(hours)" : "\(minutes)", main, false, 0, 0),
            (":", .tertiary, false, 0.02, 0.02),
            (String(format: "%02d", hours > 0 ? minutes : rest), main, false, 0, 0),
        ]
        if hours > 0 { runs.append((String(format: "%02d", rest), .secondary, true, 0.12, 0)) }
        return runs
    }

    /// 段（`Text` 1 つぶん）の幅は画素に切り上げてから次の段を並べる（SwiftUI の `Text` と同じ。並べて撮って画素単位で一致を確かめた）。
    static func layout(seconds: Int, size: CGFloat, isDimmed: Bool, scale: CGFloat, backing: CGFloat) -> Layout {
        let scaled = size * scale
        let kern = -scaled * 0.015
        var cells: [Cell] = []
        var x: CGFloat = 0
        for run in runs(seconds: seconds, isDimmed: isDimmed) {
            x += scaled * run.leading
            let runX = x
            let font = font(size: run.isSmall ? scaled * 0.4 : scaled)
            var inner: CGFloat = 0
            for character in run.text {
                cells.append(Cell(piece: Piece(character: character, role: run.role, isSmall: run.isSmall), x: runX + inner, runX: runX))
                inner += advance(of: character, font: font, kern: kern)
            }
            x += ceil(inner * backing) / backing + scaled * run.trailing
        }
        return Layout(cells: cells, width: x, scale: scale)
    }

    static func fittingLayout(seconds: Int, size: CGFloat, isDimmed: Bool, width: CGFloat?, backing: CGFloat) -> Layout {
        var smallest: Layout?
        for scale in fittingScales {
            let layout = layout(seconds: seconds, size: size, isDimmed: isDimmed, scale: scale, backing: backing)
            guard let width, layout.width > width + 0.5 else { return layout }
            smallest = layout
        }
        return smallest!
    }

    private static func advance(of character: Character, font: NSFont, kern: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [.font: font, .kern: kern]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // MARK: - 更新

    func update(seconds: Int, size: CGFloat, isDimmed: Bool, animated: Bool) {
        let styleChanged = size != self.size || isDimmed != self.isDimmed
        let previous = self.seconds
        self.seconds = seconds
        self.size = size
        self.isDimmed = isDimmed
        guard styleChanged || previous != seconds else { return }
        // 値だけが変わったときに転がす。最初の表示・大きさや色の変更・アニメーションを切った更新は、そのまま差し替える
        let rolling = animated && !styleChanged && previous != nil && window != nil
        rebuild(rolling: rolling, countsDown: (previous ?? 0) > seconds)
    }

    override func layout() {
        super.layout()
        rebuild(rolling: false, countsDown: false)
    }

    /// 文字は窓の画素にそろえて置くので、自分の位置の端数が変わったら置き直す（大きさが変わらない移動では layout が呼ばれない）。
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let before = convertToBacking(NSPoint.zero)
        super.setFrameOrigin(newOrigin)
        let after = convertToBacking(NSPoint.zero)
        if (before.x - after.x).truncatingRemainder(dividingBy: 1) != 0 || (before.y - after.y).truncatingRemainder(dividingBy: 1) != 0 {
            rebuild(rolling: false, countsDown: false)
        }
    }

    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glyphs = [:]
        refreshImages()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glyphs = [:]
        refreshImages()
    }

    private func refreshImages() {
        guard current != nil else { return }
        // 位置と画像の端数も含めて置き直す
        layers.forEach { $0.removeFromSuperlayer() }
        layers = []
        self.current = nil
        rebuild(rolling: false, countsDown: false)
    }

    /// 文字の層を並べ直す。右端からそろえて同じ位置の文字と比べ（9:59 → 10:00 のように桁が増えても右の桁どうしが対応する）、
    /// 同じ文字の層は使い続け、違う文字だけを入れ替える。`rolling` なら入れ替えを転がして見せ、ずれた文字は滑らせる。
    private func rebuild(rolling: Bool, countsDown: Bool) {
        guard let seconds, let layer, bounds.width > 0 else { return }
        let backing = backingScale
        let next = Self.fittingLayout(seconds: seconds, size: size, isDimmed: isDimmed, width: availableWidth ?? bounds.width, backing: backing)
        let scaled = size * next.scale
        let font = Self.font(size: scaled)
        // 画素へのそろえは自分の中ではなく窓の画素で行う（SwiftUI が自分を画素の途中に置いても、文字は SwiftUI の Text と同じ画素に乗る）
        let origin = convertToBacking(NSPoint.zero)
        // 小さい段は縦の中央に置く（SwiftUI の ZStack(alignment: .leading) と同じ）。基準線は上端から ascender 下で、画素の下側にそろえる
        let lineTop = (bounds.height - ceil(Self.lineHeight(size: scaled) * backing) / backing) / 2
        let baseline = ((origin.y + (bounds.height - lineTop - font.ascender) * backing).rounded(.up) - origin.y) / backing
        let oldCells = current?.cells ?? []
        let shift = oldCells.count - next.cells.count
        var newLayers: [CALayer] = []
        var used = Set<Int>()
        var rolled = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, cell) in next.cells.enumerated() {
            // 段の始まりを窓の画素にそろえ、段の中の文字の端数は画像に焼き込む（x は窓の画素）
            let x = (origin.x + cell.runX * backing).rounded() + (cell.x - cell.runX) * backing
            let subpixel = Int(((x - x.rounded(.down)) * 8).rounded())
            let glyph = glyph(for: cell.piece, scale: next.scale, subpixel: subpixel)
            let frame = CGRect(x: (x.rounded(.down) + (subpixel == 8 ? 1 : 0) - origin.x) / backing - glyph.padding, y: baseline - glyph.baseline,
                               width: glyph.size.width, height: glyph.size.height)
            let oldIndex = index + shift
            let old = oldCells.indices.contains(oldIndex) ? layers[oldIndex] : nil
            if let old, oldCells[oldIndex].piece == cell.piece {
                used.insert(oldIndex)
                old.contents = glyph.image
                if rolling, old.frame != frame { slide(old, to: frame) } else { old.frame = frame }
                newLayers.append(old)
                continue
            }
            let fresh = CALayer()
            fresh.contents = glyph.image
            fresh.contentsScale = backing
            fresh.frame = frame
            layer.addSublayer(fresh)
            newLayers.append(fresh)
            if old != nil { used.insert(oldIndex) }
            if rolling {
                roll(out: old, in: fresh, delay: Double(rolled) * Self.stagger, countsDown: countsDown, scaled: scaled)
                rolled += 1
            } else {
                old?.removeFromSuperlayer()
            }
        }
        // 桁が減ったときに対応のない層
        for (index, old) in layers.enumerated() where !used.contains(index) {
            if rolling { roll(out: old, in: nil, delay: 0, countsDown: countsDown, scaled: scaled) } else { old.removeFromSuperlayer() }
        }
        CATransaction.commit()
        layers = newLayers
        current = next
    }

    // MARK: - 動き（numericText に合わせる。古い数字はぼけて縮みながら上へ抜け、新しい数字はぼけたまま下から上がってくる）

    /// 桁ごとのずらし（左の桁から順に）
    private static let stagger: CFTimeInterval = 0.14

    private func roll(out old: CALayer?, in new: CALayer?, delay: CFTimeInterval, countsDown: Bool, scaled: CGFloat) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let offset = scaled * 0.25 * (countsDown ? -1 : 1)
        let shrunk: CGFloat = 0.78
        let blur = scaled * 0.06
        let start = CACurrentMediaTime() + delay
        // 古い数字: すぐに動き出し、ぼけながら約 0.14 秒で消える
        if let old {
            var animations = [Self.timed(Self.basic("opacity", from: 1, to: 0), 0.14, Self.linear)]
            if !reduceMotion {
                attachBlur(to: old)
                animations += [Self.timed(Self.basic("transform", from: CATransform3DIdentity, to: Self.shifted(offset, scale: shrunk)), 0.2, Self.easeOut),
                               Self.timed(Self.basic("filters.blur.inputRadius", from: 0, to: blur), 0.12, Self.easeOut)]
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = reduceMotion ? 0.14 : 0.2
            group.beginTime = start
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { old.removeFromSuperlayer() }
            old.add(group, forKey: "rollOut")
            CATransaction.commit()
        }
        // 新しい数字: 少し遅れて下に現れ、約 0.35 秒で上がりきる。ぼけは約 0.4 秒かけて取れる
        if let new {
            var animations = [Self.timed(Self.basic("opacity", from: 0, to: 1), 0.15, Self.linear)]
            if !reduceMotion {
                attachBlur(to: new)
                animations += [Self.timed(Self.basic("transform", from: Self.shifted(-offset, scale: shrunk), to: CATransform3DIdentity), 0.36, Self.rise),
                               Self.timed(Self.basic("filters.blur.inputRadius", from: blur, to: 0), 0.42, Self.easeOut)]
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = reduceMotion ? 0.15 : 0.42
            group.beginTime = start + 0.045
            group.fillMode = .backwards
            CATransaction.begin()
            // 止まったあとはぼかしを外す（半径 0 でも合成のたびに通さない）
            CATransaction.setCompletionBlock { new.filters = nil }
            new.add(group, forKey: "rollIn")
            CATransaction.commit()
        }
    }

    private static let linear = CAMediaTimingFunction(name: .linear)
    private static let easeOut = CAMediaTimingFunction(controlPoints: 0.25, 0.6, 0.4, 1)
    /// 新しい数字が上がる動き。始めは速く、終わりはゆっくり（SwiftUI の snappy に近い。録画のコマ送りで合わせた）
    private static let rise = CAMediaTimingFunction(controlPoints: 0.25, 0.7, 0.3, 1)

    private static func timed(_ animation: CABasicAnimation, _ duration: CFTimeInterval, _ timing: CAMediaTimingFunction) -> CABasicAnimation {
        animation.duration = duration
        animation.timingFunction = timing
        animation.fillMode = .both
        return animation
    }

    /// 桁数が変わって位置がずれる文字は、転がりと同じ速さで滑らせる。
    private func slide(_ layer: CALayer, to frame: CGRect) {
        let from = layer.position
        layer.frame = frame
        let animation = Self.basic("position", from: from, to: layer.position)
        animation.duration = 0.36
        animation.timingFunction = Self.rise
        layer.add(animation, forKey: "slide")
    }

    private func attachBlur(to layer: CALayer) {
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.name = "blur"
        filter.setValue(0, forKey: kCIInputRadiusKey)
        layer.filters = [filter]
    }

    private static func shifted(_ y: CGFloat, scale: CGFloat) -> CATransform3D {
        CATransform3DScale(CATransform3DMakeTranslation(0, y, 0), scale, scale, 1)
    }

    private static func basic(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    // MARK: - 数字の画像（CoreText で描いて使い回す）

    private func glyph(for piece: Piece, scale: CGFloat, subpixel: Int) -> Glyph {
        let scaled = size * scale
        let fontSize = piece.isSmall ? scaled * 0.4 : scaled
        let backing = backingScale
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = GlyphKey(piece: piece, fontSize: fontSize, kern: -scaled * 0.015, backingScale: backing, isDark: isDark, subpixel: subpixel % 8)
        if let cached = glyphs[key] { return cached }
        var color = CGColor(gray: 0, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved: NSColor = switch piece.role {
            case .primary: .labelColor
            case .secondary: .secondaryLabelColor
            case .tertiary: .tertiaryLabelColor
            }
            color = resolved.cgColor
        }
        let string = NSAttributedString(string: String(piece.character), attributes: [
            .font: Self.font(size: fontSize), .kern: key.kern, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        // 余白（ぼかしのはみ出し用）と基準線は画素にそろえ、層を置いたときに拡大縮小させない
        let padding = ceil(fontSize * 0.2)
        let baseline = ceil((padding + descent) * backing) / backing
        let pixelWidth = Int(ceil((max(advance, 1) + padding * 2) * backing))
        let pixelHeight = Int(ceil((baseline + ascent + padding) * backing))
        let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: backing, y: backing)
        context.textPosition = CGPoint(x: padding + CGFloat(key.subpixel) / 8 / backing, y: baseline)
        CTLineDraw(line, context)
        let glyph = Glyph(image: context.makeImage()!, size: CGSize(width: CGFloat(pixelWidth) / backing, height: CGFloat(pixelHeight) / backing),
                          baseline: baseline, padding: padding)
        // 使うのは数字 10 種と記号の、大きさ・色・位置の端数の組み合わせだけ。念のため増えすぎたら作り直す
        if glyphs.count > 200 { glyphs.removeAll() }
        glyphs[key] = glyph
        return glyph
    }
}
