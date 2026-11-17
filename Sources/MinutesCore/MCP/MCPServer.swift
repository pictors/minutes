import Foundation

// MCP（Model Context Protocol）の stdio サーバーの最小実装。
// 確認した仕様: https://modelcontextprotocol.io/specification/2025-06-18
// - トランスポート: stdio。1 行に 1 つの JSON-RPC 2.0 メッセージ（UTF-8、改行を含めない）。stdout にはメッセージ以外を書かない
// - initialize → { protocolVersion, capabilities, serverInfo, instructions }。クライアントの版に対応していればその版、なければ最新の版を返す
// - notifications/initialized ほか、id のない通知には応答しない
// - tools/list → { tools: [{ name, title, description, inputSchema, annotations }] }
// - tools/call → { content: [{ type: "text", text }], isError }。ツールの中の失敗は isError で返し、JSON-RPC のエラーにしない
// - prompts/list → { prompts: [{ name, title, description, arguments }] }、prompts/get → { description, messages: [{ role, content }] }
// - ping → {}

/// JSON の値（JSON-RPC のメッセージを組み立て・読むため）。
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .int(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .double(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .int(value): return value
        case let .double(value) where value.rounded() == value: return Int(value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .string(value): return ["true", "1"].contains(value.lowercased()) ? true : ["false", "0"].contains(value.lowercased()) ? false : nil
        default: return nil
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}

/// MCP のツール。
public struct MCPTool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool

    public init(name: String, title: String, description: String, inputSchema: JSONValue, readOnly: Bool = true) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }

    var json: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
            "annotations": ["readOnlyHint": .bool(readOnly), "openWorldHint": false],
        ]
    }
}

/// MCP のプロンプト（クライアントの「/」から選べる定型の頼み方）。
public struct MCPPrompt: Sendable {
    public struct Argument: Sendable {
        public var name: String
        public var description: String
        public var required: Bool

        public init(name: String, description: String, required: Bool = false) {
            self.name = name
            self.description = description
            self.required = required
        }
    }

    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]

    public init(name: String, title: String, description: String, arguments: [Argument]) {
        self.name = name
        self.title = title
        self.description = description
        self.arguments = arguments
    }

    var json: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "arguments": .array(arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] }),
        ]
    }
}

/// ツールの中の失敗。tools/call の結果に isError: true で返す（モデルが読んで言い直せるように）。
public struct MCPToolError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// MCP サーバーが提供する中身（ツールとプロンプト）。
public protocol MCPHandler {
    var serverName: String { get }
    var serverTitle: String { get }
    var serverVersion: String { get }
    var instructions: String { get }
    var tools: [MCPTool] { get }
    var prompts: [MCPPrompt] { get }
    /// ツールを実行して本文（テキスト）を返す。失敗は `MCPToolError` などを投げる。
    func callTool(name: String, arguments: [String: JSONValue]) throws -> String
    /// プロンプトを組み立てて、利用者の発言として渡す本文を返す。
    func prompt(name: String, arguments: [String: String]) throws -> String
}

/// JSON-RPC の 1 行を受けて、応答の 1 行（通知なら nil）を返す。トランスポート（stdin/stdout）は呼び出し側が持つ。
public struct MCPServer<Handler: MCPHandler> {
    public static var supportedProtocolVersions: [String] { ["2025-06-18", "2025-03-26", "2024-11-05"] }

    public let handler: Handler

    public init(handler: Handler) {
        self.handler = handler
    }

    enum RPCError: Error {
        case parse, invalidRequest, methodNotFound(String), invalidParams(String)

        var code: Int {
            switch self {
            case .parse: -32700
            case .invalidRequest: -32600
            case .methodNotFound: -32601
            case .invalidParams: -32602
            }
        }

        var message: String {
            switch self {
            case .parse: "Parse error"
            case .invalidRequest: "Invalid Request"
            case let .methodNotFound(method): "Method not found: \(method)"
            case let .invalidParams(detail): "Invalid params: \(detail)"
            }
        }
    }

    /// 1 行を処理する。空行・通知・応答（クライアントからの result）には nil を返す。
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return Self.encode(errorResponse(id: .null, error: .parse))
        }
        // バッチ（配列）は 2025-06-18 で外れたが、古い版のクライアントのために 1 件ずつ処理する
        if case let .array(items) = message {
            guard !items.isEmpty else { return Self.encode(errorResponse(id: .null, error: .invalidRequest)) }
            let responses = items.compactMap(handle(message:))
            return responses.isEmpty ? nil : Self.encode(.array(responses))
        }
        return handle(message: message).map(Self.encode)
    }

    func handle(message: JSONValue) -> JSONValue? {
        guard case .object = message, let method = message["method"]?.stringValue else {
            // クライアントからの応答（result / error）は使わない
            if message["result"] != nil || message["error"] != nil { return nil }
            return errorResponse(id: message["id"] ?? .null, error: .invalidRequest)
        }
        // id のないものは通知で、応答しない
        guard let id = message["id"], id != .null else { return nil }
        let params = message["params"] ?? [:]
        do {
            return ["jsonrpc": "2.0", "id": id, "result": try result(method: method, params: params)]
        } catch let error as RPCError {
            return errorResponse(id: id, error: error)
        } catch {
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string(error.localizedDescription)]]
        }
    }

    func result(method: String, params: JSONValue) throws -> JSONValue {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.supportedProtocolVersions[0]
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
                "serverInfo": ["name": .string(handler.serverName), "title": .string(handler.serverTitle), "version": .string(handler.serverVersion)],
                "instructions": .string(handler.instructions),
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(handler.tools.map(\.json))]
        case "tools/call":
            guard let name = params["name"]?.stringValue else { throw RPCError.invalidParams("name がありません") }
            guard handler.tools.contains(where: { $0.name == name }) else { throw RPCError.invalidParams("不明なツール: \(name)") }
            let arguments: [String: JSONValue]
            switch params["arguments"] {
            case nil, .null?: arguments = [:]
            case let .object(object)?: arguments = object
            default: throw RPCError.invalidParams("arguments はオブジェクトにしてください")
            }
            do {
                let text = try handler.callTool(name: name, arguments: arguments)
                return ["content": [["type": "text", "text": .string(text)]], "isError": false]
            } catch {
                return ["content": [["type": "text", "text": .string(error.localizedDescription)]], "isError": true]
            }
        case "prompts/list":
            return ["prompts": .array(handler.prompts.map(\.json))]
        case "prompts/get":
            guard let name = params["name"]?.stringValue else { throw RPCError.invalidParams("name がありません") }
            guard let prompt = handler.prompts.first(where: { $0.name == name }) else { throw RPCError.invalidParams("不明なプロンプト: \(name)") }
            var arguments: [String: String] = [:]
            if case let .object(object)? = params["arguments"] {
                for (key, value) in object { if let text = value.stringValue { arguments[key] = text } }
            }
            let text: String
            do { text = try handler.prompt(name: name, arguments: arguments) } catch { throw RPCError.invalidParams(error.localizedDescription) }
            return [
                "description": .string(prompt.description),
                "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]],
            ]
        default:
            throw RPCError.methodNotFound(method)
        }
    }

    func errorResponse(id: JSONValue, error: RPCError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]]
    }

    static func encode(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // JSONEncoder は改行をエスケープするので、1 行に収まる
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"encode failed"}}"#
    }
}
