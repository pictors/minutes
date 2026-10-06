import Foundation

/// 要約に使うローカル CLI（codex / claude）。設定画面の選択肢と実行時の解決に、同じ探し方を使う。
public enum SummaryCLI: Sendable {
    case codex, claudeCode

    /// コマンド名（codex / claude）。
    public var command: String {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude"
        }
    }

    /// 実際に使う実行ファイル。設定値があればそれだけを使い、なければ自動検出の先頭。見つからなければ nil。
    public func executable(configuredPath: String?) -> URL? {
        switch self {
        case .codex: try? CodexAppServerClient.executable(configuredPath: configuredPath)
        case .claudeCode: try? ClaudeCodeClient.executable(configuredPath: configuredPath)
        }
    }

    /// 自動検出で見つかる実行ファイル（確認する順。先頭を自動で使う）。
    public func candidates() -> [URL] {
        switch self {
        case .codex: CodexAppServerClient.executableCandidates()
        case .claudeCode: ClaudeCodeClient.executableCandidates()
        }
    }

    /// アプリに同梱の CLI。codex は ChatGPT / Codex アプリに同梱される。claude を同梱するアプリはない。
    public func executable(inApplication application: URL) -> URL? {
        switch self {
        case .codex: CodexAppServerClient.bundledExecutable(in: application)
        case .claudeCode: nil
        }
    }

    /// 実行ファイルを同梱しているアプリ。同梱でなければ nil。
    public static func application(containing executable: URL) -> URL? {
        ExecutableSearch.application(containing: executable)
    }

    /// `--version` で起動できるかと版を確かめる（設定画面で候補を見分けるため。会議データは渡さない）。
    public static func probe(_ executable: URL) async -> ExecutableProbe {
        await ExecutableSearch.probe(executable)
    }
}

/// `--version` で確かめた実行ファイルの状態。
public enum ExecutableProbe: Sendable, Equatable {
    /// 起動でき、版を読めた（"0.159.2" など）
    case version(String)
    /// 起動できたが、出力から版を読めない
    case unknownVersion
    /// 起動できない・異常終了・タイムアウト
    case failed
}

/// GUI 起動では PATH が狭いので、PATH のあとに既知のインストール先も確認する。
enum ExecutableSearch {
    /// configuredPath: 設定値。空でなければそれだけを使い（~ は展開、絶対パスのみ）、見つからなければ nil。
    /// preferred: PATH より先に確認する場所（デスクトップアプリの同梱 CLI など）。fallbacks: 最後に確認する場所。
    static func find(_ name: String, configuredPath: String?, preferred: [String] = [], fallbacks: [String] = []) -> URL? {
        if let path = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/"), isExecutable(atPath: expanded) else { return nil }
            return URL(fileURLWithPath: expanded)
        }
        return candidates(name, preferred: preferred, fallbacks: fallbacks).first
    }

    /// 見つかる実行ファイルを確認する順に返す（先頭を自動で使う）。
    /// 同じアプリに同梱のもの（起動用スクリプトと本体など）と、同じ実体へのリンクは最初の 1 つにまとめる。
    static func candidates(_ name: String, preferred: [String] = [], fallbacks: [String] = []) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = preferred + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/\(name)" }
            + [home.appendingPathComponent(".local/bin/\(name)").path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] + fallbacks
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard path.hasPrefix("/"), isExecutable(atPath: path) else { return nil }
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath()
            return seen.insert(application(containing: resolved)?.path ?? resolved.path).inserted ? url : nil
        }
    }

    /// 実行できるファイル（リンクは辿る）。フォルダは除く。
    static func isExecutable(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// 実行ファイルを同梱しているアプリ（パスのうち最も外側の .app）。
    static func application(containing executable: URL) -> URL? {
        let components = executable.pathComponents.dropLast()
        guard let index = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...index])), isDirectory: true)
    }

    /// 新しい実行ファイルの初回起動はシステムの検査で数秒かかることがあるので、タイムアウトは長めにする。
    static func probe(_ executable: URL, timeoutSeconds: Double = 10) async -> ExecutableProbe {
        guard let output = try? await ClaudeCodeProcess.run(executable: executable, arguments: ["--version"],
                                                           directory: FileManager.default.temporaryDirectory,
                                                           environment: ProcessInfo.processInfo.environment,
                                                           input: Data(), timeoutSeconds: timeoutSeconds),
              output.status == 0 else { return .failed }
        return parseVersion(String(decoding: output.stdout, as: UTF8.self)).map(ExecutableProbe.version) ?? .unknownVersion
    }

    /// "codex-cli 0.159.2" → "0.159.2"、"2.1.272 (Claude Code)" → "2.1.272"。
    static func parseVersion(_ text: String) -> String? {
        text.firstMatch(of: /\d+\.\d+(?:\.\d+)*(?:-[0-9A-Za-z.]+)?/).map { String($0.output) }
    }
}
