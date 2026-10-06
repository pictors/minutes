import AppKit
import SwiftUI

/// 設定 > 情報: 版・著作権・ライセンスと、第三者のソフトウェアとモデルの帰属表示（NOTICE と同じ内容。SPEC §12 Phase 1.5）。
/// 全文は .app に同梱した LICENSE と NOTICE を表示する（`scripts/build-app.sh` が入れる）。
struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var showingNotice = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Minutes").font(.title2.weight(.semibold))
                        Text(AppInfo.versionLabel)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(AppInfo.copyright).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("ライセンス") { Text("Apache License 2.0") }
                LabeledContent("ソースコード") {
                    Link("github.com/pictors/minutes", destination: AppInfo.repository)
                }
            }
            Section {
                if model.updates.isAvailable {
                    Toggle("新しい版を自動で確認する", isOn: Binding(get: { model.updates.automaticallyChecks },
                                                          set: { model.updates.automaticallyChecks = $0 }))
                    LabeledContent("最後の確認") {
                        Text(model.updates.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "まだ確認していません")
                    }
                    HStack {
                        Button(model.updates.pendingVersion.map { "新しい版（\($0)）を入れる…" } ?? "今すぐ確認…") {
                            model.updates.checkForUpdates()
                        }
                        Spacer()
                    }
                } else {
                    Text("このビルドは自動更新を使いません（開発用のビルド）。")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("アップデート")
            } footer: {
                Text("1 日に 1 回、GitHub から更新の情報を読みます。新しい版は、確かめてから入れます。")
            }
            Section {
                ForEach(Acknowledgement.all) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Link(item.name, destination: item.url)
                            Spacer(minLength: 8)
                            Text(item.license).foregroundStyle(.secondary)
                        }
                        Text(item.attribution)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Button("ライセンスと帰属表示の全文…") { showingNotice = true }
                    Spacer()
                }
            } header: {
                Text("謝辞")
            } footer: {
                Text("話者分離のモデルは、この Mac で初めて話者分離をするときに Hugging Face からダウンロードします。音声認識は macOS の SpeechAnalyzer を使います。")
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
        .sheet(isPresented: $showingNotice) { NoticeSheet() }
    }
}

enum AppInfo {
    static let repository = URL(string: "https://github.com/pictors/minutes")!
    static var copyright: String {
        Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 Pictors Inc."
    }

    static var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発版"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "版 \(version)（\($0)）" } ?? "版 \(version)"
    }
}

/// 第三者のソフトウェアとモデル。NOTICE と合わせて直す。
struct Acknowledgement: Identifiable {
    let name: String
    let url: URL
    let license: String
    let attribution: String
    var id: String { name }

    static let all: [Acknowledgement] = [
        Acknowledgement(name: "GRDB.swift", url: URL(string: "https://github.com/groue/GRDB.swift")!, license: "MIT",
                        attribution: "Copyright (C) 2015-2025 Gwendal Roué"),
        Acknowledgement(name: "FluidAudio", url: URL(string: "https://github.com/FluidInference/FluidAudio")!, license: "Apache-2.0",
                        attribution: "Fluid Inference。VBx（Brno University of Technology, BUT Speech@FIT、Apache-2.0）と fastcluster（© 2011 Daniel Müllner、1.1.24 以降の変更は © Google Inc.、BSD 2-Clause）を含む。"),
        Acknowledgement(name: "Sparkle", url: URL(string: "https://sparkle-project.org/")!, license: "MIT",
                        attribution: "Andy Matuschak ほか。自動更新に使う。bsdiff（Colin Percival）、sais-lite（Yuta Mori）、Ed25519（Orson Peters）、SUSignatureVerifier（Mark Hamlin）を含む。"),
        Acknowledgement(name: "話者分離のモデル（speaker-diarization-coreml）", url: URL(string: "https://huggingface.co/FluidInference/speaker-diarization-coreml")!, license: "CC BY 4.0",
                        attribution: "pyannote の speaker-diarization-community-1、WeSpeaker の話者埋め込み、Brno University of Technology（BUT Speech@FIT）の PLDA パラメータを、Fluid Inference が Core ML に変換・改変したもの。"),
    ]
}

/// LICENSE と NOTICE の全文。
private struct NoticeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ライセンスと帰属表示").font(.headline)
            ScrollView {
                Text(Self.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
            HStack {
                Link("ソースコードの NOTICE を開く", destination: AppInfo.repository.appendingPathComponent("blob/main/NOTICE"))
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 560)
    }

    /// .app に同梱した NOTICE と LICENSE。`swift run` などで見つからなければ、リポジトリの NOTICE を案内する。
    private static let text: String = {
        let parts = ["NOTICE", "LICENSE"].compactMap { name in
            Bundle.main.url(forResource: name, withExtension: nil).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        return parts.isEmpty ? "このビルドには NOTICE と LICENSE が入っていません。ソースコードの NOTICE と LICENSE を見てください。" : parts.joined(separator: "\n\n")
    }()
}
