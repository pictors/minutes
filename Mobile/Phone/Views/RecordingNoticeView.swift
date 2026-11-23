import SwiftUI

/// 最初の録音の前に一度だけ: 録音の告知と、音声の送り先・保存の期間（ガイドライン 2.5.14、5.1.1）。
struct RecordingNoticeView: View {
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    item("person.2.wave.2", "参加者に伝える",
                         "録音する前に、録音すること・議事録を作ることを参加者に伝え、了承を得てください。録音中は画面にそのことを表示します。")
                    item("icloud.and.arrow.up", "音声の送り先",
                         "録音した音声は Pictors のサーバーに送り、文字起こし（ElevenLabs）と要約（Anthropic の Claude）に使います。")
                    item("calendar.badge.clock", "保存の期間",
                         "音声は 30 日でサーバーから消えます。文字起こしと議事録は、会議やアカウントを消すまで残ります。いつでも消せます。")
                }
                .padding()
            }
            .navigationTitle("録音の前に")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    onAccept()
                } label: {
                    Text("わかりました")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
    }

    private func item(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary)
            }
        }
    }
}
