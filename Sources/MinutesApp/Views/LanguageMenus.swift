import MinutesCore
import SwiftUI

/// 見出しの右端の小さなカプセル（次の録音のプライバシー・言語、録音中の言語で共通）。
struct HeaderCapsuleLabel: View {
    let systemImage: String
    /// nil なら記号だけ（見出しの会議名・副題に場所を残す）。
    let title: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .contentTransition(.symbolEffect(.replace))
            if let title {
                Text(title)
                    .contentTransition(.opacity)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Surface.card, in: .capsule)
        .contentShape(.capsule)
    }
}

/// 次の録音の言語（パネルの見出しの右端。待機中）。
struct NextLanguageMenu: View {
    @Binding var choice: MeetingLanguageChoice

    var body: some View {
        Menu {
            Picker("次の録音の言語", selection: $choice) {
                ForEach(MeetingLanguageChoice.allCases, id: \.self) { choice in
                    Text(choice.menuTitle).tag(choice)
                }
            }
            .pickerStyle(.inline)
        } label: {
            // 既定の「自動」は記号だけにして、副題（録音するアプリ）を削らない
            HeaderCapsuleLabel(systemImage: "globe", title: choice == .auto ? nil : choice.title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("次の録音の言語（\(choice.title)）。自動は日本語で字幕を出し、会議のあとで英語の会議かを判定します")
    }
}

/// 録音中のライブ字幕と会議の言語（パネルの見出しと録音画面の字幕の見出し）。
/// 選ぶとすぐ字幕がその言語に変わり、会議のあとの文字起こしと要約もその言語になる。
struct LiveLanguageMenu: View {
    @Environment(AppModel.self) private var model
    var preparation: LivePreparation?

    var body: some View {
        let choice = model.liveLanguageChoice ?? .auto
        Menu {
            Section("字幕と会議の言語") {
                ForEach(MeetingLanguage.allCases, id: \.self) { language in
                    Button {
                        model.setLiveLanguage(language)
                    } label: {
                        if choice.language == language {
                            Label(language.title, systemImage: "checkmark")
                        } else {
                            Text(language.title)
                        }
                    }
                }
            }
            if choice == .auto {
                Text("自動: 日本語で字幕を出し、会議のあとで英語の会議かを判定します")
            }
        } label: {
            HeaderCapsuleLabel(systemImage: preparation?.isDownloading == true ? "arrow.down.circle" : "globe", title: choice.title)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("ライブ字幕と会議の言語（\(choice.title)）。切り替えると、会議のあとの文字起こしと要約もその言語になります")
    }
}

extension MeetingLanguageChoice {
    /// メニューの項目名。
    var menuTitle: String {
        switch self {
        case .auto: "自動（日本語と英語）"
        case .ja: "日本語"
        case .en: "英語"
        }
    }
}

extension LivePreparation {
    var locale: Locale {
        switch self {
        case let .preparing(locale, _), let .ready(locale), let .failed(locale, _): locale
        }
    }

    var isDownloading: Bool {
        if case .preparing(_, _?) = self { return true }
        return false
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    private var languageTitle: String { MeetingLanguage(code: locale.identifier)?.title ?? locale.identifier }

    /// 画面に出す一言（用意できていれば nil）。
    var statusText: String? {
        switch self {
        case let .preparing(_, progress?):
            "\(languageTitle)の字幕のモデルをダウンロード中 \(Int((progress * 100).rounded()))%"
        case .preparing, .ready:
            nil
        case .failed:
            "\(languageTitle)の字幕に切り替えられませんでした。字幕は元の言語で続けます"
        }
    }
}
