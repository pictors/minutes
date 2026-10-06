import Foundation
import Testing
@testable import MinutesCore

/// 設定画面の実行ファイルの選択肢（自動検出の候補・アプリの同梱 CLI・版）。
struct ExecutableSearchTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-executables-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeExecutable(_ url: URL, script: String = "#!/bin/sh\nexit 0\n", permissions: Int = 0o755) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    @Test("候補は自動検出と同じ順で、同じアプリに同梱の CLI は 1 つにまとめる")
    func codexCandidates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        let packaged = root.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let legacy = root.appendingPathComponent("Codex.app/Contents/Resources/codex")
        for url in [launcher, packaged, legacy] { try makeExecutable(url) }

        let candidates = CodexAppServerClient.executableCandidates(applicationRoots: [root])
        let bundled = candidates.filter { $0.path.hasPrefix(root.path) }
        #expect(bundled.map(\.path) == [launcher.path, legacy.path])
        #expect(candidates.first?.path == launcher.path)
        #expect(try CodexAppServerClient.executable(configuredPath: nil, applicationRoots: [root]).path == launcher.path)
    }

    @Test("リンクは実体ごとに 1 つ。実行できないファイルとフォルダは候補にしない")
    func candidateFiltering() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("real/tool")
        let link = root.appendingPathComponent("bin/tool")
        let plain = root.appendingPathComponent("plain/tool")
        let folder = root.appendingPathComponent("folder/tool")
        try makeExecutable(tool)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
        try makeExecutable(plain, permissions: 0o644)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let name = "minutes-test-\(UUID().uuidString)"
        let found = ExecutableSearch.candidates(name, preferred: [plain.path, folder.path, link.path, tool.path, "relative/tool"])
        #expect(found.map(\.path) == [link.path])
        #expect(ExecutableSearch.find(name, configuredPath: folder.path) == nil)
        #expect(ExecutableSearch.find(name, configuredPath: plain.path) == nil)
        #expect(ExecutableSearch.find(name, configuredPath: link.path)?.path == link.path)
    }

    @Test("選んだアプリに同梱の CLI を新しい形式から探す")
    func bundledExecutable() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        let packaged = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        let legacy = app.appendingPathComponent("Contents/Resources/codex")
        try makeExecutable(packaged)
        try makeExecutable(legacy)
        #expect(SummaryCLI.codex.executable(inApplication: app)?.path == packaged.path)
        #expect(SummaryCLI.claudeCode.executable(inApplication: app) == nil)
        let empty = root.appendingPathComponent("Other.app", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(SummaryCLI.codex.executable(inApplication: empty) == nil)
    }

    @Test("同梱元のアプリはパスのうち最も外側の .app")
    func containingApplication() {
        let inner = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        #expect(SummaryCLI.application(containing: inner)?.path == "/Applications/ChatGPT.app")
        #expect(SummaryCLI.application(containing: URL(fileURLWithPath: "/opt/homebrew/bin/codex")) == nil)
        #expect(SummaryCLI.application(containing: URL(fileURLWithPath: "/tmp/tool.app")) == nil)
    }

    @Test("--version の出力から版を読む", arguments: [
        ("codex-cli 0.159.2\n", "0.159.2"),
        ("2.1.272 (Claude Code)\n", "2.1.272"),
        ("codex-cli 0.160.0-alpha.1", "0.160.0-alpha.1"),
        ("unknown", nil),
    ] as [(String, String?)])
    func parseVersion(output: String, expected: String?) {
        #expect(ExecutableSearch.parseVersion(output) == expected)
    }

    @Test("起動して版を確かめる。起動できない・異常終了は failed")
    func probe() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let versioned = root.appendingPathComponent("versioned")
        try makeExecutable(versioned, script: "#!/bin/sh\n[ \"$1\" = --version ] && echo 'codex-cli 1.2.3'\n")
        let silent = root.appendingPathComponent("silent")
        try makeExecutable(silent, script: "#!/bin/sh\necho ok\n")
        let broken = root.appendingPathComponent("broken")
        try makeExecutable(broken, script: "#!/bin/sh\necho 'codex-cli 1.2.3'\nexit 1\n")
        #expect(await SummaryCLI.probe(versioned) == .version("1.2.3"))
        #expect(await SummaryCLI.probe(silent) == .unknownVersion)
        #expect(await SummaryCLI.probe(broken) == .failed)
        #expect(await SummaryCLI.probe(root.appendingPathComponent("missing")) == .failed)
    }
}
