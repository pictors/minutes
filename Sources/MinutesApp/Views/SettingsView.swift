import AppKit
import Combine
import EventKit
import MinutesCore
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: String, CaseIterable, Sendable {
    case recording, providers, export, calendar, people, appearance, diagnostics, about
}

/// 設定（SPEC §10.3）。変更は 0.5 秒後に自動で保存・適用する。API キーはプロバイダの行で入力し、Keychain に保存する。
/// 録音中は録音に影響する項目だけを無効化し、キー・書き出し先・カレンダーは変更できる（次の後処理から適用）。
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = AppSettings()
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var selection: SettingsTab = .recording

    static let paneHeight: CGFloat = 640

    var body: some View {
        TabView(selection: $selection) {
            Tab("録音", systemImage: "record.circle", value: .recording) { RecordingSettingsPane(draft: $draft) }
            Tab("プロバイダ", systemImage: "cloud", value: .providers) { ProviderSettingsPane(draft: $draft) }
            Tab("書き出し", systemImage: "square.and.arrow.up", value: .export) { ExportSettingsPane(draft: $draft) }
            Tab("カレンダー", systemImage: "calendar", value: .calendar) { CalendarSettingsPane(draft: $draft) }
            Tab("人物と用語", systemImage: "person.2", value: .people) { PeopleAndTermsPane() }
            Tab("外観", systemImage: "circle.lefthalf.filled", value: .appearance) { AppearanceSettingsPane(draft: $draft) }
            Tab("診断", systemImage: "stethoscope", value: .diagnostics) { DiagnosticsPane() }
            Tab("情報", systemImage: "info.circle", value: .about) { AboutPane() }
        }
        .frame(width: 680)
        .windowResizeAnchor(.top)
        .onAppear(perform: load)
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: model.requestedSettingsTab) { _, tab in consumeRequestedTab(tab) }
        // メニューバーのパネルで切り替えたテーマを下書きにも反映する（古い値で上書き保存しない）
        .onChange(of: model.settings.appearance) { _, appearance in
            if draft.appearance != appearance { draft.appearance = appearance }
        }
    }

    private func load() {
        draft = model.settings
        loaded = true
        consumeRequestedTab(model.requestedSettingsTab)
    }

    private func consumeRequestedTab(_ tab: SettingsTab?) {
        guard let tab else { return }
        selection = tab
        model.requestedSettingsTab = nil
    }

    private func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            var settings = draft
            if settings.exportDirectory == AppSettings().exportDirectoryURL.path { settings.exportDirectory = nil }
            guard settings != model.settings else { return }
            model.updateSettings(settings)
        }
    }
}

// MARK: - 録音

struct RecordingSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AppSettings
    @State private var inputDevices: [AudioInputDevice] = []

    private var defaultInputName: String? { inputDevices.first(where: \.isDefault)?.name ?? MicCapture.defaultInputDeviceName() }

    private var silenceChoices: [Double] {
        Array(Set([60.0, 120, 180, 300, 600, 900] + [draft.silenceTimeoutSeconds])).sorted()
    }

    private var retentionChoices: [Int] {
        Array(Set([7, 14, 30, 60, 90, 180, 365] + [draft.audioRetentionDays])).sorted()
    }

    var body: some View {
        Form {
            if model.isRecording {
                Section {
                    Banner(kind: .warning, text: "録音中は録音対象・マイク・自動開始の設定を変更できません。録音が終わってから変更してください。")
                }
            }
            Section {
                ForEach(draft.targetBundleIdentifiers, id: \.self) { bundleID in
                    TargetAppRow(bundleID: bundleID) { remove(bundleID) }
                }
                if draft.targetBundleIdentifiers.isEmpty {
                    Text("会議に使うアプリを追加してください")
                        .foregroundStyle(.secondary)
                }
                AddTargetAppRow(targets: draft.targetBundleIdentifiers) { add($0) }
            } header: {
                Text("録音対象アプリ")
            } footer: {
                Text("録音開始時に、起動している対象アプリの中から録るアプリを選べます。会議は専用ブラウザで開く運用（タブ単位では切り出せません）。")
            }
            .disabled(model.isRecording)
            Section("録音") {
                Toggle("自分の声（マイク）も録音する", isOn: $draft.includeMic)
                Picker("マイク", selection: $draft.micDevice) {
                    Text("システムの既定" + (defaultInputName.map { "（\($0)）" } ?? "")).tag(String?.none)
                    if !inputDevices.isEmpty { Divider() }
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                    if let uid = draft.micDevice, !inputDevices.contains(where: { $0.uid == uid }) {
                        Text("（接続されていません）\(uid)").tag(String?.some(uid))
                    }
                }
                .disabled(!draft.includeMic)
                .help("見つからないときはシステムの既定入力で録音します")
                TextField("自分の表示名", text: Binding(get: { draft.selfName ?? "" }, set: { draft.selfName = $0.isEmpty ? nil : $0 }), prompt: Text("自分"))
                Toggle("カレンダーの会議で音声を検知したら自動で録音を開始する", isOn: $draft.autoStartOnAudio)
                Toggle("自動開始の前に確認する（通知と画面のボタンで開始）", isOn: $draft.confirmBeforeAutoStart)
                    .disabled(!draft.autoStartOnAudio)
                Picker("無音で自動停止", selection: $draft.silenceTimeoutSeconds) {
                    ForEach(silenceChoices, id: \.self) { seconds in
                        Text("\(Int(seconds / 60)) 分").tag(seconds)
                    }
                }
            }
            .disabled(model.isRecording)
            Section {
                Picker("既定のプライバシー", selection: $draft.defaultPrivacyMode) {
                    ForEach(PrivacyMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Picker("音声の保持期間", selection: $draft.audioRetentionDays) {
                    ForEach(retentionChoices, id: \.self) { days in
                        Text("\(days) 日").tag(days)
                    }
                }
            } header: {
                Text("プライバシーと保持")
            } footer: {
                Text("ローカルのみの会議はクラウドへ送信せず、書き出し・同期も行いません。録音準備中（会議開始前）の自分の声は会議に含めず、送信しません。音声は書き出し済みで保持期間を過ぎたものだけ削除します。")
            }
            Section {
                LabeledContent("録音の開始 / 停止") {
                    ShortcutRecorder(shortcut: $draft.globalShortcut, registrationError: model.shortcutError)
                }
            } header: {
                Text("グローバルショートカット")
            } footer: {
                Text("他のアプリが前面でも効きます（システムの許可は不要）。待機中は録音を開始、録音準備中は今すぐ開始、録音中は停止します。結果は通知で知らせます。")
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
        .task { inputDevices = MicCapture.inputDevices() }
    }

    private func add(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !draft.targetBundleIdentifiers.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        withAnimation(.snappy) { draft.targetBundleIdentifiers.append(trimmed) }
    }

    private func remove(_ bundleID: String) {
        withAnimation(.snappy) { draft.targetBundleIdentifiers.removeAll { $0 == bundleID } }
    }
}

struct TargetAppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var body: some View {
        HStack(spacing: 10) {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "app.dashed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(appURL.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                Text(appURL == nil ? "この Mac にはインストールされていません" : bundleID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("削除")
        }
    }
}

/// 録音対象アプリを追加する行。起動中のアプリか、アプリケーションフォルダから選ぶ。
/// bundle ID の直接入力は、この Mac にないアプリや、別の bundle ID のプロセスで音を鳴らすアプリを指定するための予備。
struct AddTargetAppRow: View {
    let targets: [String]
    let onAdd: (String) -> Void
    @State private var runningApps: [RunningAppChoice] = []
    @State private var enteringBundleID = false
    @State private var bundleIDInput = ""
    @State private var failure: String?
    @FocusState private var fieldFocused: Bool

    /// 対象に入っているアプリは候補から外す。
    private var candidates: [RunningAppChoice] {
        runningApps.filter { !BundleIDMatcher.matches($0.bundleID, targets: targets) }
    }

    private var trimmedInput: String { bundleIDInput.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if enteringBundleID {
                bundleIDField
            } else {
                addMenu
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(Palette.amber)
                    .textSelection(.enabled)
            }
        }
        .onAppear(perform: refreshRunningApps)
        // 設定を開いたまま会議アプリを起動・終了しても、候補を最新に保つ
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in refreshRunningApps() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in refreshRunningApps() }
    }

    private var addMenu: some View {
        Menu {
            Section("起動中のアプリ") {
                if candidates.isEmpty {
                    Button("追加できるアプリは起動していません") {}
                        .disabled(true)
                }
                ForEach(candidates) { app in
                    Button {
                        failure = nil
                        onAdd(app.bundleID)
                    } label: {
                        Label {
                            Text(app.name)
                        } icon: {
                            if let icon = app.icon { Image(nsImage: icon) }
                        }
                    }
                }
            }
            Divider()
            Button("その他のアプリを選ぶ…", action: chooseApps)
            Button("bundle ID を入力…") {
                failure = nil
                enteringBundleID = true
                // 欄が現れてから（.task / onAppear で）指定してもフォーカスが入らないので、出すのと同時に指定する
                fieldFocused = true
            }
        } label: {
            // 行のアイコンの列に「＋」を置き、アプリ名と頭をそろえる
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.body.weight(.medium))
                    .frame(width: 26, height: 26)
                Text("アプリを追加")
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tint)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("起動中のアプリか、アプリケーションフォルダから選んで追加")
    }

    private var bundleIDField: some View {
        HStack(spacing: 8) {
            TextField("bundle ID", text: $bundleIDInput, prompt: Text("com.example.app"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .labelsHidden()
                .focused($fieldFocused)
                .onSubmit(submitBundleID)
                .onExitCommand(perform: endBundleIDEntry)
            Button("追加", action: submitBundleID)
                .disabled(trimmedInput.isEmpty)
            Button("キャンセル", action: endBundleIDEntry)
        }
    }

    private func refreshRunningApps() {
        runningApps = RunningAppChoice.current()
    }

    private func submitBundleID() {
        guard !trimmedInput.isEmpty else { return }
        onAdd(trimmedInput)
        endBundleIDEntry()
    }

    private func endBundleIDEntry() {
        bundleIDInput = ""
        enteringBundleID = false
    }

    /// アプリケーションフォルダを開いて選ばせる（設定ウィンドウのシートとして出す）。
    private func chooseApps() {
        failure = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.message = "録音対象にするアプリを選んでください"
        panel.prompt = "追加"
        guard let window = NSApp.keyWindow else {
            if panel.runModal() == .OK { addApps(at: panel.urls) }
            return
        }
        Task {
            guard await panel.beginSheetModal(for: window) == .OK else { return }
            addApps(at: panel.urls)
        }
    }

    private func addApps(at urls: [URL]) {
        var unreadable: [String] = []
        for url in urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                onAdd(bundleID)
            } else {
                unreadable.append(FileManager.default.displayName(atPath: url.path))
            }
        }
        failure = unreadable.isEmpty ? nil : "\(unreadable.joined(separator: "、")) の bundle ID を読み取れませんでした"
    }
}

/// 追加の候補に出す起動中のアプリ（Dock に出る通常のアプリ。Minutes 自身は除く）。
struct RunningAppChoice: Identifiable {
    let bundleID: String
    let name: String
    /// メニューの項目に合わせて 16pt にした複製
    let icon: NSImage?
    var id: String { bundleID }

    @MainActor
    static func current() -> [RunningAppChoice] {
        var seen: Set<String> = []
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> RunningAppChoice? in
                guard app.activationPolicy == .regular, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier,
                      seen.insert(bundleID.lowercased()).inserted else { return nil }
                return RunningAppChoice(bundleID: bundleID, name: app.localizedName ?? bundleID, icon: app.icon?.menuIcon)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension NSImage {
    /// メニューの項目に合わせて 16pt にした複製。
    var menuIcon: NSImage {
        let copy = copy() as? NSImage ?? self
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }
}

// MARK: - 外観

struct AppearanceSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AppSettings

    var body: some View {
        Form {
            Section {
                HStack(spacing: 20) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        AppearanceOption(appearance: appearance, selected: draft.appearance == appearance) {
                            draft.appearance = appearance
                            // 見た目の切り替えは保存の待ち時間を置かずに当てる
                            model.setAppearance(appearance)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } header: {
                Text("テーマ")
            } footer: {
                Text("メニューバーのパネル・ウィンドウ・設定に適用します。「システムに合わせる」は macOS の外観（ライト / ダーク / 自動）に従います。メニューバーのパネル下端のボタンからも切り替えられます。")
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
    }
}

struct AppearanceOption: View {
    let appearance: AppAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AppearanceThumbnail(appearance: appearance)
                    .frame(width: 118, height: 76)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
                    }
                Text(appearance.title)
                    .font(.callout)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// メニューバーのパネルを小さく描いた見本。「システムに合わせる」は斜めに半分ずつ。
struct AppearanceThumbnail: View {
    let appearance: AppAppearance

    var body: some View {
        switch appearance {
        case .light:
            PanelSample(dark: false)
        case .dark:
            PanelSample(dark: true)
        case .system:
            ZStack {
                PanelSample(dark: false)
                PanelSample(dark: true)
                    .mask {
                        GeometryReader { geometry in
                            Path { path in
                                let size = geometry.size
                                path.move(to: CGPoint(x: size.width * 0.62, y: 0))
                                path.addLine(to: CGPoint(x: size.width, y: 0))
                                path.addLine(to: CGPoint(x: size.width, y: size.height))
                                path.addLine(to: CGPoint(x: size.width * 0.38, y: size.height))
                                path.closeSubpath()
                            }
                        }
                    }
            }
        }
    }

    /// 見本の色は外観の解決に頼らず固定値で描く（見本どうしで同じ色になるように）。
    private struct PanelSample: View {
        let dark: Bool

        var body: some View {
            let ink = dark ? Color.white : Color.black
            let bars: [UInt32] = dark ? [0x8C91FA, 0xFF5A24, 0xF7C62F, 0x33C9EB] : [0x4F54D9, 0xD63F0A, 0xA87400, 0x0A84A8]
            let widths: [CGFloat] = [34, 22, 13, 9]
            ZStack(alignment: .topLeading) {
                Color(nsColor: .rgb(dark ? 0x2C2C2F : 0xF4F4F6))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(nsColor: .rgb(bars[0])).opacity(0.35))
                            .frame(width: 11, height: 11)
                        Capsule().fill(ink.opacity(0.5)).frame(width: 38, height: 4)
                    }
                    HStack(alignment: .center) {
                        Text(verbatim: "12:48")
                            .font(.system(size: 16, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(ink)
                        Spacer(minLength: 4)
                        Capsule()
                            .fill(ink.opacity(0.1))
                            .frame(width: 32, height: 14)
                            .overlay(alignment: .leading) {
                                Circle().fill(Color(nsColor: .rgb(dark ? 0xFF4A3D : 0xD92D22))).frame(width: 10, height: 10).padding(.leading, 2)
                            }
                    }
                    HStack(spacing: 2) {
                        ForEach(bars.indices, id: \.self) { index in
                            Capsule().fill(Color(nsColor: .rgb(bars[index]))).frame(width: widths[index], height: 4)
                        }
                    }
                }
                .padding(10)
            }
            .clipShape(.rect(cornerRadius: 11, style: .continuous))
        }
    }
}

// MARK: - プロバイダ

struct ProviderSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AppSettings
    @State private var codex: ConnectionCheck = .idle
    @State private var codexConnection: CodexConnection?
    @State private var codexRefresh = 0
    @State private var claudeCode: ConnectionCheck = .idle
    @State private var claudeCodeConnection: ClaudeCodeConnection?
    @State private var claudeCodeRefresh = 0

    enum ConnectionCheck: Equatable {
        case idle, checking, ok(String), failed(String)
    }

    private var finalEntry: ProviderCatalog.Entry? { ProviderCatalog.final(draft.finalProviderId) }

    /// 変わったら接続とモデル一覧を確認し直す。Codex 以外を選んでいる間は nil。
    private var codexLookup: String? {
        draft.resolvedSummaryProvider == .codex ? "\(draft.codexExecutablePath ?? "")\n\(codexRefresh)" : nil
    }

    /// 変わったらログイン状態を確認し直す。Claude Code 以外を選んでいる間は nil。
    private var claudeCodeLookup: String? {
        draft.resolvedSummaryProvider == .claudeCode ? "\(draft.claudeCodeExecutablePath ?? "")\n\(claudeCodeRefresh)" : nil
    }

    private var codexModels: [CodexModel] { codexConnection?.models ?? [] }

    /// 一覧にない設定値（非表示のモデルや CLI で指定したモデル）も選択肢に残し、選択を失わない。
    private var codexModelChoices: [CodexModel] {
        guard let current = draft.codexModel, !codexModels.contains(where: { $0.id == current }) else { return codexModels }
        return codexModels + [CodexModel(id: current, displayName: current)]
    }

    private var codexDefaultTitle: String {
        codexConnection?.defaultModel.map { "Codex の既定（\($0.displayName)）" } ?? "Codex の既定"
    }

    private var codexModelDetail: String? {
        if let connection = codexConnection, connection.models.isEmpty { return "Codex からモデル一覧を取得できませんでした" }
        let detail: String?
        if let id = draft.codexModel {
            detail = codexModels.first { $0.id == id }?.description ?? (codexConnection == nil ? nil : "Codex のモデル一覧にありません")
        } else {
            detail = codexConnection?.defaultModel?.description
        }
        return detail.flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        Form {
            Section {
                Picker("確定文字起こし", selection: $draft.finalProviderId) {
                    ForEach(ProviderCatalog.finalProviders) { entry in
                        Text(entry.title).tag(entry.id)
                    }
                }
                if let entry = finalEntry, let key = entry.keyName {
                    APIKeyRow(name: key, provider: entry.title)
                        .id(key)
                } else {
                    LabeledContent("状態") {
                        Label("端末内で処理", systemImage: "desktopcomputer")
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("要約で学習した用語を次回の keyterms に追加する", isOn: $draft.keytermsAutoLearn)
            } footer: {
                Text((finalEntry.map { $0.detail + "。" } ?? "")
                     + "ローカルのみの会議とクラウド失敗時は常にローカルを使います。"
                     + (finalEntry?.keyName == nil ? "" : "キーは Keychain に保存し、.env / 環境変数より優先します。")
                     + "変更は次の後処理から適用されます。学習した用語は「人物と用語」で確認・削除できます。")
            }
            Section {
                Picker("要約", selection: Binding(get: { draft.resolvedSummaryProvider }, set: { draft.summaryProvider = $0 })) {
                    Text("Codex app server（既定）").tag(SummaryProvider.codex)
                    Text("Claude Code").tag(SummaryProvider.claudeCode)
                    Text("Anthropic API").tag(SummaryProvider.anthropic)
                    Divider()
                    Text("要約しない").tag(SummaryProvider.none)
                }
                switch draft.resolvedSummaryProvider {
                case .codex:
                    Picker(selection: $draft.codexModel) {
                        Text(codexDefaultTitle).tag(String?.none)
                        if !codexModelChoices.isEmpty {
                            Divider()
                            ForEach(codexModelChoices) { entry in
                                Text(entry.displayName).tag(String?.some(entry.id))
                            }
                        }
                    } label: {
                        Text("モデル")
                        if let detail = codexModelDetail { Text(detail) }
                    }
                    ExecutablePickerRow(cli: .codex, path: $draft.codexExecutablePath, refresh: codexRefresh)
                    LabeledContent("接続") {
                        HStack(spacing: 8) {
                            connectionStatus(codex)
                            Button(codex == .checking ? "確認中…" : "接続を確認") { codexRefresh += 1 }
                                .disabled(codex == .checking)
                        }
                    }
                case .claudeCode:
                    ClaudeCodeModelRow(model: $draft.claudeCodeModel, connection: claudeCodeConnection)
                    ExecutablePickerRow(cli: .claudeCode, path: $draft.claudeCodeExecutablePath, refresh: claudeCodeRefresh)
                    LabeledContent("接続") {
                        HStack(spacing: 8) {
                            connectionStatus(claudeCode)
                            Button(claudeCode == .checking ? "確認中…" : "接続を確認") { claudeCodeRefresh += 1 }
                                .disabled(claudeCode == .checking)
                        }
                    }
                case .anthropic:
                    TextField("モデル", text: $draft.summaryModel)
                    APIKeyRow(name: APIKeys.anthropic, provider: "Anthropic")
                case .none:
                    EmptyView()
                }
            } header: {
                Text("要約")
            } footer: {
                switch draft.resolvedSummaryProvider {
                case .codex:
                    Text("Codex CLI のログインを使用します。未ログインならターミナルで codex login を実行してください。「Codex の既定」は Codex の設定（config.toml）のモデルに従います。モデルの変更は次の要約から使われます。要約時は会議の文字起こしを Codex に送信します。ローカルのみの会議では要約しません。")
                case .claudeCode:
                    Text("Claude Code のログインを使用し、利用量は Claude のプランの上限に数えられます。未ログインならターミナルで claude auth login を実行してください。「Claude Code の既定」は Claude Code の設定（/model や settings.json）のモデルに従います。一覧にないモデル名は「その他…」で指定できます。モデルの変更は次の要約から使われます。ツール・CLAUDE.md・MCP は使いません。要約時は会議の文字起こしを Anthropic に送信します。ローカルのみの会議では要約しません。")
                case .anthropic:
                    Text("キーは Keychain に保存し、.env / 環境変数より優先します。要約時は会議の文字起こしを Anthropic に送信します。ローカルのみの会議では要約しません。")
                case .none:
                    Text("要約を作らず、文字起こしまでの議事録を作ります。Codex か Claude Code にログインするか、Anthropic の API キーを登録すると要約できます。")
                }
            }
            Section {
                Picker("会議の言語", selection: $draft.meetingLanguage) {
                    Text("自動（日本語と英語）").tag(MeetingLanguageChoice.auto)
                    Text("日本語").tag(MeetingLanguageChoice.ja)
                    Text("英語").tag(MeetingLanguageChoice.en)
                }
                Picker("英語の会議の要約", selection: $draft.englishSummaryLanguage) {
                    Text("英語").tag(MeetingLanguage.en)
                    Text("日本語").tag(MeetingLanguage.ja)
                }
            } header: {
                Text("会議の言語")
            } footer: {
                Text("自動は、ライブ字幕を日本語で始め、会議のあとで英語の会議かを判定します。録音中はメニューバーのパネルや録音画面で言語を切り替えられます。英語のライブ字幕のモデルは、初めて英語を選んだときにダウンロードします。会議の言語と要約の言語は、会議の画面であとから変えられます。")
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
        .animation(.snappy, value: draft.resolvedSummaryProvider)
        .task(id: codexLookup) { await checkCodex() }
        .task(id: claudeCodeLookup) { await checkClaudeCode() }
    }

    @ViewBuilder
    private func connectionStatus(_ check: ConnectionCheck) -> some View {
        switch check {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .ok(let account):
            Label("接続済み（\(account)）", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Palette.mint)
                .lineLimit(1)
                .textSelection(.enabled)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.amber)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    /// ログインとモデル一覧を読む（推論なし・会議データなし）。実行ファイルを続けて切り替えてもプロセスを起動し続けないよう少し待つ。
    private func checkCodex() async {
        guard codexLookup != nil else { return }
        codex = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let connection = try await CodexSummarizer(executablePath: draft.codexExecutablePath, timeoutSeconds: 20).checkConnection()
            codexConnection = connection
            codex = .ok(connection.account)
        } catch {
            guard !Task.isCancelled else { return }
            codexConnection = nil
            codex = .failed(error.localizedDescription)
        }
    }

    /// ログインとモデル一覧を読む（推論なし・会議データなし）。実行ファイルを続けて切り替えてもプロセスを起動し続けないよう少し待つ。
    private func checkClaudeCode() async {
        guard claudeCodeLookup != nil else { return }
        claudeCode = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do {
            let connection = try await ClaudeCodeSummarizer(executablePath: draft.claudeCodeExecutablePath, timeoutSeconds: 20).checkConnection()
            claudeCodeConnection = connection
            claudeCode = .ok(connection.label)
        } catch {
            guard !Task.isCancelled else { return }
            claudeCodeConnection = nil
            claudeCode = .failed(error.localizedDescription)
        }
    }
}

/// プロバイダの行で API キーを登録・変更・削除する。キーは Keychain（jp.pictors.minutes）に保存し、
/// 設定ファイルやリポジトリには書き込まない。未登録なら .env / 環境変数のキーを使う。
struct APIKeyRow: View {
    @Environment(AppModel.self) private var model
    let name: String
    let provider: String
    /// 表示のたびに Keychain を読まないよう、表示時とキーの変更時にだけ確認する。
    @State private var status: KeyStatus?
    @State private var editing = false
    @State private var input = ""
    @State private var error: String?
    @State private var confirmingDelete = false
    @FocusState private var fieldFocused: Bool

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        LabeledContent("API キー") {
            VStack(alignment: .trailing, spacing: 4) {
                if editing || status == .missing {
                    HStack(spacing: 8) {
                        SecureField("", text: $input, prompt: Text("キーを貼り付け"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .focused($fieldFocused)
                            .onSubmit(save)
                            .onExitCommand(perform: cancel)
                        Button("保存", action: save)
                            .disabled(trimmedInput.isEmpty)
                        if editing {
                            Button("キャンセル", action: cancel)
                        }
                    }
                } else if let status {
                    HStack(spacing: 8) {
                        Label(status.title, systemImage: status.symbol)
                            .foregroundStyle(status.tint)
                        if status == .keychain {
                            Button("変更", action: beginEditing)
                            Button("削除", role: .destructive) { confirmingDelete = true }
                        } else {
                            Button("Keychain に登録", action: beginEditing)
                        }
                    }
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Palette.record)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: model.apiKeysRevision) { _, _ in refresh() }
        .confirmationDialog("\(provider) の API キーを削除しますか？", isPresented: $confirmingDelete) {
            Button("削除", role: .destructive, action: delete)
        } message: {
            Text("Keychain から削除します。.env / 環境変数にキーがあれば、以後はそちらを使います。")
        }
    }

    private func refresh() {
        status = KeyStatus.resolve(name)
    }

    private func beginEditing() {
        error = nil
        editing = true
        // 欄が現れてから（.task で）指定してもフォーカスが入らないので、出すのと同時に指定する
        fieldFocused = true
    }

    private func cancel() {
        input = ""
        error = nil
        editing = false
    }

    private func save() {
        guard !trimmedInput.isEmpty else { return }
        do {
            try model.saveAPIKey(input, name: name)
            cancel()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() {
        do { try model.deleteAPIKey(name: name) } catch { self.error = error.localizedDescription }
    }
}

/// Claude Code のモデルを選ぶ行。既定（--model を渡さない）か、Claude Code が返す一覧のモデルを選び、
/// 一覧にないエイリアス・モデル名は「その他…」で入力する。行の下に選んだモデルの説明を出す。
struct ClaudeCodeModelRow: View {
    @Binding var model: String?
    /// 接続確認の結果。確認中・失敗のあいだは nil。
    let connection: ClaudeCodeConnection?
    @State private var entering = false
    @State private var input = ""

    private enum Selection: Hashable {
        case automatic, model(String), other
    }

    private var models: [ClaudeCodeModel] { connection?.models ?? [] }

    /// 一覧にない設定値（「その他…」や CLI で指定したモデル）も選択肢に残し、選択を失わない。
    private var choices: [ClaudeCodeModel] {
        guard let model, !models.contains(where: { $0.id == model }) else { return models }
        return models + [ClaudeCodeModel(id: model, displayName: model)]
    }

    private var defaultTitle: String {
        connection?.defaultModel.map { "Claude Code の既定（\($0.displayName)）" } ?? "Claude Code の既定"
    }

    private var detail: String? {
        if let connection, connection.models.isEmpty { return "Claude Code からモデル一覧を取得できませんでした" }
        let detail: String?
        if let model {
            detail = models.first { $0.id == model }?.description ?? (connection == nil ? nil : "Claude Code の一覧にないモデル（そのまま --model に渡します）")
        } else {
            detail = connection?.defaultModel?.description
        }
        return detail.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var selection: Binding<Selection> {
        Binding(
            get: { model.map(Selection.model) ?? .automatic },
            set: { selection in
                switch selection {
                case .automatic: model = nil
                case .model(let value): model = value
                case .other:
                    // 一覧にない指定を直すときだけ、今の値を入れておく
                    input = model.flatMap { value in models.contains { $0.id == value } ? nil : value } ?? ""
                    entering = true
                }
            }
        )
    }

    var body: some View {
        // 「その他…」を選んでも選択の値は変えないので、入力を閉じれば元の項目の表示に戻る
        Picker(selection: selection) {
            Text(defaultTitle).tag(Selection.automatic)
            if !choices.isEmpty {
                Divider()
                ForEach(choices) { entry in
                    Text(entry.displayName).tag(Selection.model(entry.id))
                }
            }
            Divider()
            Text("その他…").tag(Selection.other)
        } label: {
            Text("モデル")
            if let detail { Text(detail) }
        }
        .alert("モデルを指定", isPresented: $entering) {
            TextField("モデル", text: $input)
            Button("指定", action: commit)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("Claude Code の --model に渡すエイリアス（sonnet など）かモデル名（claude-sonnet-5 など）を入力してください。")
        }
    }

    private func commit() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        model = value
    }
}

/// 要約に使う CLI（codex / claude）の実行ファイルを選ぶ行。既定は自動検出で、見つかった CLI（版つき）か、
/// 「その他…」で選んだファイル・アプリに固定できる。行の下に実際に使うパスを出す。
struct ExecutablePickerRow: View {
    let cli: SummaryCLI
    @Binding var path: String?
    /// 変わったら候補を探し直し、版を確かめ直す（「接続を確認」）
    let refresh: Int
    @State private var candidates: [ExecutableChoice] = []
    @State private var probes: [String: ExecutableProbe] = [:]
    @State private var probedRefresh: Int?

    private enum Selection: Hashable {
        case automatic, path(String), other
    }

    private struct ReloadKey: Hashable {
        let refresh: Int
        let path: String?
    }

    /// 実際に使う実行ファイル。指定先が見つからなければ nil（ほかの CLI には戻らない）。
    private var resolved: URL? {
        path == nil ? candidates.first?.url : cli.executable(configuredPath: path)
    }

    /// 候補にない指定（「その他…」で選んだもの、見つからなくなったもの）。
    private var custom: ExecutableChoice? {
        guard let path, candidate(matching: path) == nil else { return nil }
        return ExecutableChoice(URL(fileURLWithPath: (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath))
    }

    private var selection: Binding<Selection> {
        Binding(
            get: {
                guard let path else { return .automatic }
                return .path(candidate(matching: path)?.id ?? path)
            },
            set: { selection in
                switch selection {
                case .automatic: path = nil
                case .path(let value): path = value
                case .other: chooseFile()
                }
            }
        )
    }

    var body: some View {
        let custom = custom
        let resolved = resolved
        LabeledContent {
            // 「その他…」を選んでも選択の値は変えないので、パネルを閉じれば元の項目の表示に戻る
            Picker("実行ファイル", selection: selection) {
                menuItem(automaticTitle, for: candidates.first).tag(Selection.automatic)
                if !candidates.isEmpty { Divider() }
                ForEach(candidates) { choice in
                    menuItem(title(choice), for: choice).tag(Selection.path(choice.id))
                }
                if let custom, let path {
                    menuItem(custom.exists ? title(custom) : "（見つかりません）\(custom.name)", for: custom).tag(Selection.path(path))
                }
                Divider()
                Text("その他…").tag(Selection.other)
            }
            .labelsHidden()
            .fixedSize()
        } label: {
            Text("実行ファイル")
            if let resolved {
                HStack(spacing: 4) {
                    Text((resolved.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(resolved.path)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([resolved])
                    } label: {
                        Image(systemName: "arrow.forward.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Finder で表示")
                    .accessibilityLabel("Finder で表示")
                }
            }
        }
        // 最初の表示で行の高さが変わらないよう、描く前に探しておく（版は task で読む）
        .onAppear(perform: scan)
        .task(id: ReloadKey(refresh: refresh, path: path)) { await reload() }
    }

    /// アプリに同梱ならアプリのアイコン、それ以外の CLI はターミナルの記号。見つからないものは記号なし。
    private func menuItem(_ title: String, for choice: ExecutableChoice?) -> some View {
        Label {
            Text(title)
        } icon: {
            if let icon = choice?.applicationIcon {
                Image(nsImage: icon)
            } else if choice?.exists == true {
                Image(systemName: "terminal")
            }
        }
    }

    private var automaticTitle: String {
        guard let detected = candidates.first else { return "自動検出（見つかりません）" }
        return "自動検出（\(detected.name)" + (note(for: detected).map { "・\($0)" } ?? "") + "）"
    }

    private func title(_ choice: ExecutableChoice) -> String {
        choice.name + (note(for: choice).map { "（\($0)）" } ?? "")
    }

    /// 版か、起動できないこと。確かめている間と版を読めないときは nil。
    private func note(for choice: ExecutableChoice) -> String? {
        switch probes[choice.id] {
        case .version(let version): version
        case .failed: "起動できません"
        case .unknownVersion, nil: nil
        }
    }

    private func candidate(matching path: String) -> ExecutableChoice? {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return candidates.first { $0.id == expanded }
    }

    private func scan() {
        candidates = cli.candidates().map(ExecutableChoice.init)
    }

    /// 候補を探し直し、まだ確かめていないものだけ `--version` で版を読む（「接続を確認」のあとはすべて読み直す）。
    private func reload() async {
        scan()
        if probedRefresh != refresh {
            probes = [:]
            probedRefresh = refresh
        }
        let targets = (candidates + [custom].compactMap { $0 }).filter { $0.exists && probes[$0.id] == nil }.map(\.url)
        await withTaskGroup(of: (String, ExecutableProbe).self) { group in
            for url in targets {
                group.addTask { (url.path, await SummaryCLI.probe(url)) }
            }
            for await (key, probe) in group where !Task.isCancelled {
                probes[key] = probe
            }
        }
    }

    /// 実行できるファイルか CLI を同梱したアプリを選ぶ（設定ウィンドウのシートとして出す）。
    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Homebrew などのリンクを辿らずに保存し、CLI を更新しても同じ指定で使えるようにする
        panel.resolvesAliases = false
        if let resolved {
            panel.directoryURL = (SummaryCLI.application(containing: resolved) ?? resolved).deletingLastPathComponent()
        } else {
            panel.directoryURL = cli == .codex ? URL(filePath: "/Applications", directoryHint: .isDirectory) : FileManager.default.homeDirectoryForCurrentUser
        }
        panel.message = cli == .codex
            ? "要約に使う codex を選んでください。ChatGPT・Codex アプリを選ぶと、アプリに同梱の codex を使います。"
            : "要約に使う claude を選んでください。"
        panel.prompt = "選択"
        let filter = ExecutableFileFilter(cli: cli)
        panel.delegate = filter
        Task {
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = panel.runModal()
            }
            // パネルの delegate は弱参照なので、閉じるまで保持する
            withExtendedLifetime(filter) {}
            guard response == .OK, let url = panel.url,
                  let executable = url.pathExtension.lowercased() == "app" ? cli.executable(inApplication: url) : url else { return }
            path = executable.path
        }
    }
}

/// 実行ファイルの選択肢の表示。アプリに同梱ならアプリ名、それ以外はパス。
private struct ExecutableChoice: Identifiable {
    let url: URL
    let name: String
    let exists: Bool
    /// 同梱元のアプリのアイコン（メニューの項目の大きさ）
    let applicationIcon: NSImage?
    var id: String { url.path }

    @MainActor
    init(_ url: URL) {
        self.url = url
        exists = FileManager.default.fileExists(atPath: url.path)
        if let application = SummaryCLI.application(containing: url) {
            let display = FileManager.default.displayName(atPath: application.path)
            name = (display.hasSuffix(".app") ? String(display.dropLast(4)) : display) + " アプリに同梱"
            applicationIcon = exists ? NSWorkspace.shared.icon(forFile: application.path).menuIcon : nil
        } else {
            name = (url.path as NSString).abbreviatingWithTildeInPath
            applicationIcon = nil
        }
    }
}

/// ファイルを選ぶパネルで、実行できるファイルと CLI を同梱したアプリだけを選べるようにする（ほかは淡色になる）。
@MainActor
private final class ExecutableFileFilter: NSObject, NSOpenSavePanelDelegate {
    let cli: SummaryCLI

    init(cli: SummaryCLI) {
        self.cli = cli
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if url.pathExtension.lowercased() == "app" { return cli.executable(inApplication: url) != nil }
        // フォルダは開けるようにする。アプリ以外のパッケージは選べない
        if isDirectory.boolValue { return !NSWorkspace.shared.isFilePackage(atPath: url.path) }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}

// MARK: - 書き出し

struct ExportSettingsPane: View {
    @Binding var draft: AppSettings

    var body: some View {
        Form {
            Section {
                DirectoryField(
                    title: "フォルダ",
                    placeholder: AppSettings().exportDirectoryURL.path,
                    path: Binding(get: { draft.exportDirectory ?? "" }, set: { draft.exportDirectory = $0.isEmpty ? nil : $0 })
                )
                LabeledContent("") {
                    Button {
                        NSWorkspace.shared.open(draft.exportDirectoryURL)
                    } label: {
                        Label("Finder で開く", systemImage: "folder")
                    }
                }
            } header: {
                Text("書き出し")
            } footer: {
                Text("1 会議 = 1 フォルダで meeting.md / transcript.json / summary.json / manifest.json を書き出します。空欄なら Application Support 内に書き出します。")
            }
            Section {
                DirectoryField(
                    title: "同期先",
                    placeholder: "同期しない",
                    path: Binding(get: { draft.syncDirectory ?? "" }, set: { draft.syncDirectory = $0.isEmpty ? nil : $0 })
                )
            } header: {
                Text("同期")
            } footer: {
                Text("Google Drive / Dropbox などのフォルダを指定すると、書き出し後にコピーします。ローカルのみの会議は同期しません。")
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
    }
}

struct DirectoryField: View {
    let title: String
    let placeholder: String
    @Binding var path: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("", text: $path, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Button("選択…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true) }
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
                if !path.isEmpty {
                    Button {
                        path = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("既定に戻す")
                }
            }
        }
    }
}

// MARK: - カレンダー

struct CalendarSettingsPane: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: AppSettings
    @State private var calendars: [EKCalendar] = []
    @State private var authorized = false

    private struct SourceGroup: Identifiable {
        let title: String
        let calendars: [EKCalendar]
        var id: String { title }
    }

    private var groups: [SourceGroup] {
        let grouped = Dictionary(grouping: calendars) { $0.source?.title ?? "その他" }
        return grouped.keys.sorted().map { SourceGroup(title: $0, calendars: grouped[$0] ?? []) }
    }

    var body: some View {
        Form {
            if !authorized {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("カレンダーへのアクセスが許可されていません", systemImage: "calendar.badge.exclamationmark")
                            .foregroundStyle(Palette.amber)
                        Text("システム設定 > プライバシーとセキュリティ > カレンダー で Minutes を許可すると、会議候補と参加者を取得できます。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("システム設定を開く") { SystemSettingsLink.openPrivacy(pane: "Privacy_Calendars") }
                            Button("もう一度確認") { Task { await reload() } }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if calendars.isEmpty {
                Section {
                    Text("カレンダーがありません").foregroundStyle(.secondary)
                }
            } else {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                            Toggle(isOn: binding(for: calendar)) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(nsColor: calendar.color ?? .systemGray))
                                        .frame(width: 10, height: 10)
                                    Text(calendar.title)
                                }
                            }
                        }
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text("Meet / Teams のリンクを含む予定を会議候補にします。終日の予定と辞退した予定は除きます。未選択ならすべてのカレンダーを対象にします。")
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
        .task { await reload() }
    }

    private func reload() async {
        authorized = await model.calendar.requestAccess()
        calendars = model.calendar.calendars()
    }

    private func binding(for calendar: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { draft.calendarIdentifiers.contains(calendar.calendarIdentifier) },
            set: { on in
                if on {
                    if !draft.calendarIdentifiers.contains(calendar.calendarIdentifier) { draft.calendarIdentifiers.append(calendar.calendarIdentifier) }
                } else {
                    draft.calendarIdentifiers.removeAll { $0 == calendar.calendarIdentifier }
                }
            }
        )
    }
}

// MARK: - 人物と用語

struct PeopleAndTermsPane: View {
    @Environment(AppModel.self) private var model
    @State private var people: [PersonRecord] = []
    @State private var keyterms: [KeytermRecord] = []
    @State private var renaming: [String: String] = [:]
    @State private var newTerm = ""
    @State private var pendingDelete: PersonRecord?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                if people.isEmpty {
                    Text("話者を割り当てると人物が登録されます").foregroundStyle(.secondary)
                }
                ForEach(people) { person in
                    HStack(spacing: 10) {
                        AvatarView(name: person.name, size: 24)
                        TextField("名前", text: Binding(get: { renaming[person.id] ?? person.name }, set: { renaming[person.id] = $0 }))
                            .textFieldStyle(.plain)
                            .onSubmit { commitRename(person) }
                        if let email = person.email {
                            Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !person.voiceSamples.isEmpty {
                            InfoChip(text: "声 \(person.voiceSamples.count)", systemImage: "waveform")
                                .help("保存済みの声のサンプル")
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDelete = person
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("削除（会議の話者名は残ります）")
                    }
                }
            } header: {
                Text("人物")
            } footer: {
                Text("名前を変えると、その人物を割り当てた会議の話者名も変わります。Enter で確定。")
            }
            Section {
                HStack(spacing: 8) {
                    TextField("用語を追加", text: $newTerm, prompt: Text("固有名詞・製品名など"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addTerm)
                    Button("追加", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if keyterms.isEmpty {
                    Text("用語はまだありません").foregroundStyle(.secondary)
                }
                ForEach(keyterms, id: \.term) { record in
                    HStack(spacing: 8) {
                        Text(record.term)
                        InfoChip(text: record.source == "learned" ? "学習" : "手動")
                        Spacer()
                        Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button(role: .destructive) {
                            removeTerm(record.term)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("削除")
                    }
                }
            } header: {
                Text("用語（keyterms）")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("確定文字起こし（ElevenLabs）に送る語。新しい順に最大 1000 語。要約で学習した語は自動で追加されます（プロバイダ設定で無効化できます）。")
                    if let message { Text(message).foregroundStyle(Palette.amber) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
        .task { reload() }
        .confirmationDialog("人物を削除しますか？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete) { person in
            Button("削除", role: .destructive) { deletePerson(person) }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: { person in
            Text("「\(person.name)」と声のサンプルを削除します。会議に割り当てた話者名は残ります。")
        }
    }

    private func reload() {
        people = (try? model.store?.people()) ?? []
        keyterms = (try? model.store?.keytermRecords()) ?? []
        renaming = [:]
    }

    private func commitRename(_ person: PersonRecord) {
        guard let name = renaming[person.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != person.name else { return }
        do { try model.store?.renamePerson(id: person.id, name: name) } catch { message = error.localizedDescription }
        reload()
    }

    private func deletePerson(_ person: PersonRecord) {
        do {
            let paths = try model.store?.deletePerson(id: person.id) ?? []
            for path in paths { try? FileManager.default.removeItem(atPath: path) }
            let directory = Store.applicationSupportDirectory().appendingPathComponent("voices/\(person.id)", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
        } catch { message = error.localizedDescription }
        pendingDelete = nil
        reload()
    }

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        do { try model.store?.addKeyterms([term], source: "manual") } catch { message = error.localizedDescription }
        newTerm = ""
        reload()
    }

    private func removeTerm(_ term: String) {
        do { try model.store?.removeKeyterm(term) } catch { message = error.localizedDescription }
        reload()
    }
}

// MARK: - 診断

struct DiagnosticsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var exportMessage: String?
    @State private var exporting = false

    private var dataDirectory: URL { Store.applicationSupportDirectory() }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Button(exporting ? "書き出しています…" : "診断情報を書き出す…") {
                        exporting = true
                        Task {
                            defer { exporting = false }
                            do {
                                if let name = try await model.exportDiagnostics() { exportMessage = "書き出しました: \(name)" }
                            } catch {
                                exportMessage = "書き出せませんでした: \(error.localizedDescription)"
                            }
                        }
                    }
                    .disabled(exporting)
                    Spacer()
                }
                if let exportMessage {
                    Text(exportMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("問い合わせ")
            } footer: {
                Text("版・OS・許可・プロバイダの状態・後処理の結果・録音の統計を JSON で書き出します。本文・音声・API キーは入りません。会議名は会議の ID に置き換えます。")
            }
            Section {
                HStack {
                    Button("初回の案内を開く") {
                        openWindow(id: "onboarding")
                        NSApp.activate()
                    }
                    Spacer()
                }
            } footer: {
                Text("許可の確認・会議アプリ・文字起こしと要約の選択・試しの録音をもう一度行えます。")
            }
            Section {
                LabeledContent("データ") {
                    HStack(spacing: 6) {
                        Text(dataDirectory.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Button("Finder で開く") { NSWorkspace.shared.open(dataDirectory) }
                    }
                }
                LabeledContent("録音セッション") { Text(model.sessionState.title) }
                if let summary = model.postProcessingSummary { LabeledContent("後処理") { Text(summary) } }
            } header: {
                Text("状態")
            }
            Section {
                if model.events.isEmpty {
                    Text("ログはまだありません").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.events.enumerated().reversed()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(height: 320)
                }
                HStack {
                    Button("すべてコピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.events.joined(separator: "\n"), forType: .string)
                    }
                    .disabled(model.events.isEmpty)
                    Button("消去") { model.clearEvents() }
                        .disabled(model.events.isEmpty)
                }
            } header: {
                Text("イベントログ（新しい順）")
            } footer: {
                Text("録音・後処理・同期の出来事を最大 500 件保持します。本文・音声・API キーは含みません。問題報告に貼り付けられます。")
            }
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight)
    }
}
