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
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = parseISO8601(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "ISO 8601 の日時ではない: \(text)")
            }
            return date
        }
        return decoder
    }

    /// ISO 8601 の日時（秒の小数のあり・なしの両方）。Minutes のサーバー（JavaScript の toISOString）はミリ秒を付ける
    /// （transcript.json の created_at・録音の一覧の日時）。小数なしは今までの `.iso8601` と同じ読み方。
    public static func parseISO8601(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
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
