import Foundation
import MinutesCore

/// マイク入力デバイスの一覧（`record --mic-device <uid>` とアプリ設定の選択肢）。
enum DevicesCommand {
    static let spec = ArgumentSpec(options: [], flags: ["json"])

    struct Entry: Codable {
        var uid: String
        var name: String
        var isDefault: Bool
    }

    static func run(_ arguments: [String]) throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        let devices = MicCapture.inputDevices()
        if parsed.has("json") {
            let data = try JSONCoding.encoder().encode(devices.map { Entry(uid: $0.uid, name: $0.name, isDefault: $0.isDefault) })
            Console.out(String(decoding: data, as: UTF8.self))
            return
        }
        if devices.isEmpty {
            Console.out("入力デバイスがありません")
            return
        }
        for device in devices {
            Console.out((device.isDefault ? "* " : "  ") + device.name + "\n    uid: " + device.uid)
        }
        Console.out("")
        Console.out("\(devices.count) input devices. * = システムの既定入力。record --mic-device <uid> で指定できます。")
    }
}
