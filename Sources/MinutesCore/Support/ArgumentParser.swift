import Foundation

/// 依存を増やさないための最小限の引数パーサ（SPEC §2: 依存パッケージは最小限）。
/// 形式: `<command> [positional...] [--option value | --option=value]... [--flag]...`
public struct ArgumentSpec: Sendable {
    /// 値を取るオプション名（"--" なし）。
    public var options: Set<String>
    /// 値を取らないフラグ名。
    public var flags: Set<String>

    public init(options: Set<String> = [], flags: Set<String> = []) {
        self.options = options
        self.flags = flags
    }
}

public struct ParsedArguments: Sendable, Equatable {
    public var positionals: [String] = []
    public var options: [String: [String]] = [:]
    public var flags: Set<String> = []

    public init() {}

    public func value(_ name: String) -> String? { options[name]?.last }
    public func values(_ name: String) -> [String] { options[name] ?? [] }
    public func has(_ flag: String) -> Bool { flags.contains(flag) }

    public func int(_ name: String) throws -> Int? {
        guard let raw = value(name) else { return nil }
        guard let value = Int(raw) else { throw ArgumentError.invalidValue(option: name, value: raw, expected: "整数") }
        return value
    }

    public func double(_ name: String) throws -> Double? {
        guard let raw = value(name) else { return nil }
        guard let value = Double(raw) else { throw ArgumentError.invalidValue(option: name, value: raw, expected: "数値") }
        return value
    }

    /// カンマ区切りと繰り返し指定の両方を受け付ける（`--keyterms a,b --keyterms c`）。
    public func list(_ name: String) -> [String] {
        values(name).flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty }
    }
}

public enum ArgumentError: Error, LocalizedError, Equatable {
    case unknownOption(String)
    case missingValue(option: String)
    case invalidValue(option: String, value: String, expected: String)
    case missingRequired(String)
    case missingPositional(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownOption(name): return "不明なオプション: --\(name)"
        case let .missingValue(option): return "--\(option) には値が必要です"
        case let .invalidValue(option, value, expected): return "--\(option) の値 '\(value)' が不正です（\(expected)）"
        case let .missingRequired(name): return "--\(name) は必須です"
        case let .missingPositional(name): return "引数 <\(name)> が必要です"
        }
    }
}

public enum ArgumentParser {
    public static func parse(_ arguments: [String], spec: ArgumentSpec) throws -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0
        var onlyPositionals = false
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            if onlyPositionals || !arg.hasPrefix("--") || arg == "-" {
                parsed.positionals.append(arg)
                continue
            }
            if arg == "--" {
                onlyPositionals = true
                continue
            }
            var name = String(arg.dropFirst(2))
            var inlineValue: String? = nil
            if let eq = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if spec.flags.contains(name) {
                if let inlineValue, ["false", "no", "0"].contains(inlineValue.lowercased()) {
                    parsed.flags.remove(name)
                } else {
                    parsed.flags.insert(name)
                }
            } else if spec.options.contains(name) {
                let value: String
                if let inlineValue {
                    value = inlineValue
                } else {
                    guard index < arguments.count else { throw ArgumentError.missingValue(option: name) }
                    value = arguments[index]
                    index += 1
                }
                parsed.options[name, default: []].append(value)
            } else {
                throw ArgumentError.unknownOption(name)
            }
        }
        return parsed
    }
}
