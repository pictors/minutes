import SwiftUI

/// 最初の録音の前に一度だけ: 録音の告知と、音声の送り先・保存の期間（ガイドライン 2.5.14、5.1.1）。
struct RecordingNoticeView: View {
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MinutesMark(height: 26)
                .padding(.top, 32)
            Text("録音の前に")
                .brandDisplay(size: 34)
                .padding(.top, 18)
            Text("一度だけ確かめます。")
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 22) {
                item("person.2.wave.2.fill", Palette.periwinkle, "参加者に伝える",
                     "録音すること・議事録を作ることを参加者に伝え、了承を得てください。録音中は画面にそのことを表示します。")
                item("icloud.and.arrow.up.fill", Palette.cyan, "音声の送り先",
                     "録音した音声は Minutes のサーバーに送り、文字起こし（ElevenLabs）と要約（Anthropic の Claude）に使います。")
                item("calendar.badge.clock", Palette.mint, "保存の期間",
                     "音声は 30 日でサーバーから消えます。文字起こしと議事録は、会議やアカウントを消すまで残ります。いつでも消せます。")
            }
            .padding(.top, 32)

            Spacer(minLength: 16)

            Button("わかりました") { onAccept() }
                .buttonStyle(FilledPillButtonStyle(height: 54))
            Button("やめる") { dismiss() }
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .padding(.horizontal, 24)
        .background(Surface.page.ignoresSafeArea())
    }

    private func item(_ symbol: String, _ tint: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            TintedTile(systemImage: symbol, tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
