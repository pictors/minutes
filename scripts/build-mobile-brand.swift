#!/usr/bin/env swift
// iPhone と Watch のアプリのアイコン・起動画面の素材を、ロゴの輪郭（Mobile/Shared/BrandLogo.swift）から描いて
// Mobile/Phone/Assets.xcassets と Mobile/Watch/Assets.xcassets に置く。色は Mac のアイコン（assets/brand/minutes-b1/app-icon.png）と配色（Palette）に合わせる。
// 使い方（リポジトリの根で）: swift scripts/build-mobile-brand.swift
import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let logoSource = try String(contentsOf: root.appendingPathComponent("Mobile/Shared/BrandLogo.swift"), encoding: .utf8)

// BrandLogo.swift の mark の輪郭（M・L・C・Z の絶対座標）を読む
func markParts() -> [String] {
    guard let start = logoSource.range(of: "static let mark: [String] = ["), let end = logoSource.range(of: "]", range: start.upperBound..<logoSource.endIndex) else { return [] }
    return logoSource[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line in
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("\"") else { return nil }
        return String(text.dropFirst().prefix { $0 != "\"" })
    }
}

func cgPath(_ parts: [String]) -> CGPath {
    let path = CGMutablePath()
    for part in parts {
        var numbers: [CGFloat] = []
        var command: Character = "M"
        func flush() {
            switch command {
            case "M" where numbers.count >= 2: path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "L" where numbers.count >= 2: path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
            case "C" where numbers.count >= 6: path.addCurve(to: CGPoint(x: numbers[4], y: numbers[5]), control1: CGPoint(x: numbers[0], y: numbers[1]), control2: CGPoint(x: numbers[2], y: numbers[3]))
            case "Z": path.closeSubpath()
            default: break
            }
            numbers = []
        }
        for token in part.split(separator: " ") {
            if let first = token.first, token.count == 1, first.isLetter {
                flush()
                command = first
                if first == "Z" { flush() }
            } else if let value = Double(token) {
                numbers.append(CGFloat(value))
                if (command == "M" || command == "L") && numbers.count == 2 { flush() }
                if command == "C" && numbers.count == 6 { flush() }
            }
        }
        flush()
    }
    return path
}

let mark = cgPath(markParts())
let markBounds = mark.boundingBoxOfPath
precondition(markBounds.width > 100, "ロゴの輪郭を読めない")

func color(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// 正方形の画像に、マークを幅の markWidth 倍で中央に描く（background が nil なら透明）。
func render(size: Int, background: UInt32?, markColor: UInt32, markWidth: CGFloat) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: background == nil ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue)!
    let side = CGFloat(size)
    if let background {
        context.setFillColor(color(background))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
    let scale = side * markWidth / markBounds.width
    // 原画は上が原点。CoreGraphics は下が原点なので上下を返す
    context.translateBy(x: (side - markBounds.width * scale) / 2, y: (side + markBounds.height * scale) / 2)
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: -markBounds.minX, y: -markBounds.minY)
    context.addPath(mark)
    context.setFillColor(color(markColor))
    context.fillPath(using: .evenOdd)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func writeJSON(_ object: Any, _ path: String) throws {
    try write(try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), path)
}

func colorComponents(_ value: UInt32) -> [String: Any] {
    ["color-space": "srgb", "components": ["red": String(format: "0x%02X", (value >> 16) & 0xFF), "green": String(format: "0x%02X", (value >> 8) & 0xFF),
                                           "blue": String(format: "0x%02X", value & 0xFF), "alpha": "1.000"]]
}

func colorSet(light: UInt32, dark: UInt32) -> [String: Any] {
    ["info": ["author": "xcode", "version": 1],
     "colors": [["idiom": "universal", "color": colorComponents(light)],
                ["idiom": "universal", "appearances": [["appearance": "luminosity", "value": "dark"]], "color": colorComponents(dark)]]]
}

let info: [String: Any] = ["author": "xcode", "version": 1]
// Mac のアイコンと同じ色（地は暖かい白、マークは原画の青紫）。ダークは Palette のダークの値
let iconBackground: UInt32 = 0xF7F6F4
let iconMark: UInt32 = 0x6273E1
let darkBackground: UInt32 = 0x131316
let darkMark: UInt32 = 0x8C91FA

// iPhone: ライト・ダーク・色合いの 3 つ
let phone = "Mobile/Phone/Assets.xcassets"
try writeJSON(["info": info], "\(phone)/Contents.json")
try write(render(size: 1024, background: iconBackground, markColor: iconMark, markWidth: 0.54), "\(phone)/AppIcon.appiconset/icon-light.png")
try write(render(size: 1024, background: darkBackground, markColor: darkMark, markWidth: 0.54), "\(phone)/AppIcon.appiconset/icon-dark.png")
try write(render(size: 1024, background: 0x000000, markColor: 0xE6E6E6, markWidth: 0.54), "\(phone)/AppIcon.appiconset/icon-tinted.png")
try writeJSON(["info": info, "images": [
    ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-light.png"],
    ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-dark.png", "appearances": [["appearance": "luminosity", "value": "dark"]]],
    ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-tinted.png", "appearances": [["appearance": "luminosity", "value": "tinted"]]],
]], "\(phone)/AppIcon.appiconset/Contents.json")
try writeJSON(colorSet(light: 0x4F54D9, dark: 0x8C91FA), "\(phone)/AccentColor.colorset/Contents.json")
// 起動画面: 画面の地の色に、マークだけ
try writeJSON(colorSet(light: 0xF5F5F7, dark: 0x000000), "\(phone)/LaunchBackground.colorset/Contents.json")
var launchImages: [[String: Any]] = []
for (scale, pixels) in [(1, 96), (2, 192), (3, 288)] {
    try write(render(size: pixels, background: nil, markColor: 0x4F54D9, markWidth: 1), "\(phone)/LaunchMark.imageset/mark-light@\(scale)x.png")
    try write(render(size: pixels, background: nil, markColor: 0x8C91FA, markWidth: 1), "\(phone)/LaunchMark.imageset/mark-dark@\(scale)x.png")
    launchImages.append(["idiom": "universal", "scale": "\(scale)x", "filename": "mark-light@\(scale)x.png"])
    launchImages.append(["idiom": "universal", "scale": "\(scale)x", "filename": "mark-dark@\(scale)x.png", "appearances": [["appearance": "luminosity", "value": "dark"]]])
}
try writeJSON(["info": info, "images": launchImages], "\(phone)/LaunchMark.imageset/Contents.json")

// Watch: 丸く切り抜かれるので、マークを少し小さく
let watch = "Mobile/Watch/Assets.xcassets"
try writeJSON(["info": info], "\(watch)/Contents.json")
try write(render(size: 1024, background: iconBackground, markColor: iconMark, markWidth: 0.48), "\(watch)/AppIcon.appiconset/icon.png")
try writeJSON(["info": info, "images": [["idiom": "universal", "platform": "watchos", "size": "1024x1024", "filename": "icon.png"]]], "\(watch)/AppIcon.appiconset/Contents.json")
try writeJSON(colorSet(light: 0x8C91FA, dark: 0x8C91FA), "\(watch)/AccentColor.colorset/Contents.json")
print("built: \(phone), \(watch)")
