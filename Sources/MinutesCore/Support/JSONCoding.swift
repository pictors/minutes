import Foundation

/// プロジェクト共通の JSON エンコード/デコード設定（snake_case、ISO 8601、整形出力）。
public enum JSONCoding {
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        var format: JSONEncoder.OutputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { format.insert(.prettyPrinted) }
        encoder.outputFormatting = format
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// ミリ秒なしの ISO 8601（ローカルタイムゾーン付き）。ファイル名や frontmatter 用。
    public static func iso8601Local(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }

    /// `YYYY-MM-DD_HHmm` 形式（会議フォルダ名の先頭部分、SPEC §7.3）。
    public static func folderTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }
}
