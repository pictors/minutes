import MinutesKit
import SwiftUI

/// Minutes の Watch アプリ（製品版の P4）。録音・一覧・再生・削除は次の段で足す。いまは共通のコード（録音・送信）が watchOS でもビルドできることを保つ。
@main
struct MinutesWatchApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.title)
                Text("Minutes")
                    .font(.headline)
                Text("Watch の録音は準備中です")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
