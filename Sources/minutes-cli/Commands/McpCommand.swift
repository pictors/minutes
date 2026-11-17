import Foundation
import MinutesCore

/// MCP サーバー（stdio）。Claude Code・Claude Desktop などから Minutes の会議を読む（読み取りだけ）。
/// stdout には JSON-RPC のメッセージだけを書き、ログは stderr に出す（本文は出さない）。
enum McpCommand {
    static let spec = ArgumentSpec(options: ["db", "export-dir"], flags: [])

    static func run(_ arguments: [String]) throws {
        let parsed = try ArgumentParser.parse(arguments, spec: spec)
        let databaseURL = parsed.value("db").map { URL(fileURLWithPath: $0) } ?? Store.defaultURL()
        let exportDirectory = parsed.value("export-dir").map { URL(fileURLWithPath: $0) } ?? AppSettings.load().exportDirectoryURL
        let store = try Store.openReadOnly(at: databaseURL)
        let server = MCPServer(handler: MinutesMCPHandler(store: store, serverVersion: MinutesCLI.version, exportDirectory: exportDirectory))
        Console.info("minutes mcp: 待ち受けを始めました（読み取りだけ）")
        while let line = readLine(strippingNewline: true) {
            guard let response = server.handle(line: line) else { continue }
            FileHandle.standardOutput.write(Data((response + "\n").utf8))
        }
    }
}
