import MinutesKit
import SwiftUI

/// 話者の名前を直す（文字起こしの話者ごと）。変えたものだけを保存する。空にすると名前を消す。
struct SpeakerNamesView: View {
    let transcript: TranscriptDocument
    let onSave: ([String: String]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            // ほかのシート（共有・アカウント）と同じく、地の上のカードで組む（システムの Form は使わない）
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SectionCard("話者", systemImage: "person.2.fill", count: transcript.speakers.count, tint: .secondary) {
                        VStack(spacing: 10) {
                            ForEach(transcript.speakers, id: \.label) { speaker in
                                HStack(spacing: 12) {
                                    SpeakerBadge(label: speaker.label, name: Formatting.speaker(speaker.label, in: nil), size: 30)
                                    TextField(Formatting.speaker(speaker.label, in: nil), text: binding(speaker.label))
                                        .textContentType(.name)
                                        .submitLabel(.done)
                                        .inputField(height: 46, onCard: true, horizontalPadding: 14)
                                }
                            }
                        }
                    }
                    if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(Palette.rose)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .cardBackground()
                    }
                    Text("議事録と全文で、話者がこの名前で出ます。空にすると名前を消します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Surface.page.ignoresSafeArea())
            .navigationTitle("話者の名前")
            .navigationBarTitleDisplayMode(.inline)
            .transparentNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("やめる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(saving)
                }
            }
            .onAppear {
                names = Dictionary(uniqueKeysWithValues: transcript.speakers.map { ($0.label, $0.name ?? "") })
            }
        }
    }

    private func binding(_ label: String) -> Binding<String> {
        Binding(get: { names[label] ?? "" }, set: { names[label] = $0 })
    }

    private func save() {
        let changed = names.filter { label, name in
            (transcript.speakers.first { $0.label == label }?.name ?? "") != name.trimmingCharacters(in: .whitespacesAndNewlines)
        }.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !changed.isEmpty else {
            dismiss()
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await onSave(changed)
                dismiss()
            } catch {
                message = "保存できませんでした（\(error.localizedDescription)）"
            }
        }
    }
}
