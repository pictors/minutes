import Foundation

/// `.env` ファイルの最小実装。CLI 用（SPEC §14: CLI は .env、.gitignore 済み）。
/// 優先順位: 既存の環境変数 > カレントディレクトリの .env > 追加で指定した検索パス。
public enum DotEnv {
    /// `.env` を読み、環境変数に存在しないキーだけを返す辞書に合成する。
    public static func load(searchPaths: [URL] = defaultSearchPaths()) -> [String: String] {
        var merged: [String: String] = [:]
        for url in searchPaths.reversed() {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (key, value) in parse(text) { merged[key] = value }
        }
        for (key, value) in ProcessInfo.processInfo.environment { merged[key] = value }
        return merged
    }

    /// 指定キーの値を取得する。環境変数が最優先。
    public static func value(for key: String, searchPaths: [URL] = defaultSearchPaths()) -> String? {
        if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty { return env }
        let loaded = load(searchPaths: searchPaths)
        guard let value = loaded[key], !value.isEmpty else { return nil }
        return value
    }

    public static func defaultSearchPaths() -> [URL] {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var paths = [cwd.appendingPathComponent(".env")]
        // 実行バイナリの位置から親方向に .env を探す（swift run で .build/ 配下から起動されるケース）
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            paths.append(dir.appendingPathComponent(".env"))
            dir.deleteLastPathComponent()
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        paths.append(home.appendingPathComponent(".config/minutes/.env"))
        return paths
    }

    /// `KEY=value` / `export KEY=value` / `# comment` / クォート付き値をパースする。
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, (first == "\"" || first == "'"), value.last == first {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.firstIndex(of: "#") {
                // 行末コメント（クォートなしの場合のみ）
                value = value[..<hash].trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}
