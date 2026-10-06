import Foundation

/// MinutesCore のリソース（プロンプトなど）の所在。
/// SwiftPM 生成の `Bundle.module` は実行ファイルと同じディレクトリか、ビルドした Mac の絶対パスしか見ず、見つからないと fatalError する。
/// そこで `.app`（Contents/Resources）→ 実行ファイルの隣 → ソースツリー（テスト）の順に探し、なければ nil を返す。
/// `Bundle.module` は呼ばない（配布先の Mac で入れ忘れがあってもクラッシュさせない）。
public enum CoreResources {
    static let bundleName = "minutes_MinutesCore.bundle"

    public static func url(forResource name: String, withExtension ext: String, subdirectory: String?) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(bundleName)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let bundle = Bundle(url: candidate), let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                return url
            }
        }
        // ソースツリー（swift test など、実行ファイルの隣にバンドルがないとき）。Sources/MinutesCore/ からの相対。
        let sourceCandidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(subdirectory ?? "").appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: sourceCandidate.path) ? sourceCandidate : nil
    }
}
