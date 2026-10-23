import CoreTransferable
import MinutesCore
import SwiftUI
import UniformTypeIdentifiers

/// ドロップされた音声（SPEC §4.4）。ボイスメモからのドラッグはファイルの約束で届き、受け取ったファイルはこの処理の間しか残らないので、
/// 自分の一時フォルダへ写す。Finder からのドロップも同じく写す（元のファイルは動かさない）。
/// 確認済みの API（CoreTransferable の swiftinterface）: `FileRepresentation(importedContentType:importing:)`、`ReceivedTransferredFile.file`。
struct DroppedAudioFile: Transferable {
    static let directoryPrefix = "MinutesImport-"
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .audio) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return DroppedAudioFile(url: copy)
        }
    }
}

extension View {
    /// 音声ファイルのドロップを受け、取り込みの確認に回す。重ねている間は枠で示す。
    /// 確認済みの API（SwiftUI の swiftinterface、macOS 26）: `dropDestination(for:isEnabled:action:)`、`onDropSessionUpdated(_:)`。
    func audioImportDropTarget(_ model: AppModel, isTargeted: Binding<Bool>) -> some View {
        self
            .dropDestination(for: DroppedAudioFile.self) { items, _ in
                isTargeted.wrappedValue = false
                model.prepareImports(items.map(\.url), temporary: true)
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active: isTargeted.wrappedValue = true
                default: isTargeted.wrappedValue = false
                }
            }
    }
}

/// ドロップを受けている間の枠。
struct DropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

/// 取り込み中の表示（会議リストの下）。
struct ImportProgressBar: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(count > 1 ? "音声を取り込み中…（\(count) 件）" : "音声を取り込み中…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.bottom, 10)
    }
}

/// 取り込む前に、題名・開始日時・会議の言語・予定を確かめる（SPEC §4.4）。
struct ImportAudioSheet: View {
    @Environment(AppModel.self) private var model
    let item: PendingImport
    @State private var title = ""
    @State private var startedAt = Date()
    @State private var language: MeetingLanguage = .ja
    @State private var privacy: PrivacyMode = .cloudOk
    @State private var events: [CalendarCandidate] = []
    @State private var eventId: String?
    /// 題名を自分で書き換えたら、予定を選び直しても上書きしない。
    @State private var titleEdited = false

    private var selectedEvent: CalendarCandidate? { events.first { $0.id == eventId } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("音声を取り込む").font(.headline)
                Text("\(item.source.lastPathComponent) · \(Formatting.duration(item.probe.duration))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Form {
                Picker("予定", selection: $eventId) {
                    Text("予定なし").tag(String?.none)
                    ForEach(events) { event in
                        Text("\(event.title)（\(Formatting.timeRange(event.startDate, event.endDate))）").tag(String?.some(event.id))
                    }
                }
                .disabled(events.isEmpty)
                TextField("タイトル", text: Binding(get: { title }, set: { title = $0; titleEdited = true }),
                          prompt: Text(AudioImport.defaultTitle(for: item.source)))
                DatePicker("開始", selection: $startedAt)
                Picker("会議の言語", selection: $language) {
                    ForEach(MeetingLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("プライバシー", selection: $privacy) {
                    ForEach(PrivacyMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
            }
            .formStyle(.columns)
            Text("音声全体を相手側のトラックとして文字起こしし、話者を分けます。あなたの声も番号の話者の 1 人になります。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("キャンセル") { model.cancelImport(item) }
                    .keyboardShortcut(.cancelAction)
                Button("取り込む") { confirm() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            startedAt = item.probe.recordedAt ?? Date().addingTimeInterval(-item.probe.duration)
            language = model.settings.meetingLanguage.language ?? .ja
            privacy = model.privacyModeForNextMeeting
            reloadEvents(selectBest: true)
        }
        .onChange(of: startedAt) { _, _ in reloadEvents(selectBest: selectedEvent == nil) }
        .onChange(of: eventId) { _, _ in
            if !titleEdited { title = selectedEvent?.title ?? "" }
        }
    }

    /// 開始日時のまわりの予定を読み直す。`selectBest` なら録音と最も長く重なる予定を選ぶ。
    private func reloadEvents(selectBest: Bool) {
        events = model.importEvents(start: startedAt, duration: item.probe.duration)
        if selectBest {
            eventId = AudioImport.bestOverlap(events, start: startedAt, duration: item.probe.duration) {
                DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate))
            }?.id
        } else if selectedEvent == nil {
            eventId = nil
        }
    }

    private func confirm() {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let event = selectedEvent
        let details = AudioImport.Details(
            title: cleaned.isEmpty ? AudioImport.defaultTitle(for: item.source) : cleaned,
            startedAt: startedAt,
            language: language,
            privacy: privacy,
            platform: event?.meetingURL == nil ? nil : event?.platform,
            calendarEventId: event?.id,
            calendarTitle: event?.title,
            attendees: event?.attendees ?? []
        )
        model.confirmImport(item, details: details)
    }
}
