import Foundation
import MinutesCore

enum ProcessesCommand {
    static let spec = ArgumentSpec(options: ["app"], flags: ["json"])

    static func run(_ arguments: [String]) throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        let targets = parsed.list("app")
        let all = try AudioProcessList.all()
        let matched = targets.isEmpty ? [] : try AudioProcessList.resolve(targets: targets)
        let matchedIDs = Set(matched.map(\.objectID))

        if parsed.has("json") {
            let data = try JSONCoding.encoder().encode(all)
            Console.out(String(decoding: data, as: UTF8.self))
            return
        }
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        Console.out("  " + pad("PID", 7) + pad("OBJ", 6) + pad("OUT", 5) + pad("IN", 4) + pad("BUNDLE", 46) + "NAME")
        for process in all {
            let mark = matchedIDs.contains(process.objectID) ? "* " : "  "
            Console.out(
                mark + pad(String(process.pid), 7) + pad(String(process.objectID), 6)
                    + pad(process.isRunningOutput ? "yes" : "-", 5) + pad(process.isRunningInput ? "yes" : "-", 4)
                    + pad(String((process.bundleID ?? "-").prefix(44)), 46) + (process.name ?? "-")
            )
        }
        Console.out("")
        Console.out("\(all.count) processes. OUT = 出力ストリーム動作中。")
        if !targets.isEmpty {
            Console.out("* = --app \(targets.joined(separator: ", ")) にマッチ（\(matched.count) 件）")
            // 一覧に出ていないが解決されたもの（PID 変換で見つかったもの）
            let allIDs = Set(all.map(\.objectID))
            for process in matched where !allIDs.contains(process.objectID) {
                Console.out("  + \(process.name ?? "?") (pid \(process.pid), \(process.bundleID ?? "-"))")
            }
        }
    }
}
