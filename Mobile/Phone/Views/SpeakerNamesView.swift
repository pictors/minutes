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
            Form {
                Section {
                    ForEach(transcript.speakers, id: \.label) { speaker in
                        TextField(Formatting.speaker(speaker.label, in: nil), text: binding(speaker.label))
                            .textContentType(.name)
                    }
                } footer: {
                    Text("議事録と全文で、話者がこの名前で出ます。")
                }
                if let message {
                    Section { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("話者の名前")
            .navigationBarTitleDisplayMode(.inline)
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
