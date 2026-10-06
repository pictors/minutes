import AppKit
import Carbon.HIToolbox
import MinutesCore
import SwiftUI

/// グローバルショートカット（SPEC §6.2）。
/// Carbon の `RegisterEventHotKey` を使う。Accessibility / 入力監視の許可が不要で、他アプリが前面でも届く。
@MainActor
final class GlobalHotKeyCenter {
    private static let signature: OSType = 0x4D4E5453 // "MNTS"
    private static let hotKeyIdentifier: UInt32 = 1
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var handler: (() -> Void)?
    private(set) var registered: GlobalShortcut?
    private(set) var lastError: String?

    /// 登録し直す。nil で解除。
    func register(_ shortcut: GlobalShortcut?, handler: @escaping () -> Void) {
        unregister()
        guard let shortcut else { return }
        self.handler = handler
        if handlerRef == nil { installHandler() }
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyIdentifier)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &reference)
        if status == noErr, let reference {
            hotKeyRef = reference
            registered = shortcut
            lastError = nil
        } else {
            lastError = "ショートカット \(shortcut.display) を登録できません（OSStatus \(status)）。他のアプリが使っている可能性があります。"
            Log.cli.error("hotkey registration failed: \(status, privacy: .public)")
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    fileprivate func fire() {
        handler?()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // Carbon のアプリケーションイベントはメインスレッドで届く
            MainActor.assumeIsolated { center.fire() }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
    }

    // AppModel と同じ寿命で使う。解除は unregister()。
}

/// NSEvent → GlobalShortcut（表示文字列付き）。修飾キーが 1 つもない組み合わせは受け付けない。
enum ShortcutTranslator {
    static func shortcut(from event: NSEvent) -> GlobalShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        var display = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); display += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); display += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); display += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); display += "⌘" }
        guard carbon & ~UInt32(shiftKey) != 0 else { return nil }
        guard let keyName = keyName(for: event) else { return nil }
        return GlobalShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: carbon, display: display + keyName)
    }

    static func keyName(for event: NSEvent) -> String? {
        let special: [UInt16: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let name = special[event.keyCode] { return name }
        guard let characters = event.charactersIgnoringModifiers, let first = characters.first, !first.isWhitespace, first.isLetter || first.isNumber || first.isPunctuation || first.isSymbol else { return nil }
        return String(first).uppercased()
    }
}

/// 設定画面のショートカット記録。「記録…」を押した後の最初のキー（修飾キー付き）を取り込む。esc で中止。
struct ShortcutRecorder: View {
    @Binding var shortcut: GlobalShortcut?
    var registrationError: String?
    @State private var capturing = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(capturing ? "キーを押してください（esc で中止）" : (shortcut?.display ?? "未設定"))
                    .font(capturing ? .body : .body.monospaced())
                    .foregroundStyle(capturing ? .secondary : .primary)
                    .frame(minWidth: 140, alignment: .leading)
                Button(capturing ? "中止" : "記録…") { capturing ? stopCapture() : startCapture() }
                if shortcut != nil, !capturing {
                    Button("解除") { shortcut = nil }
                }
            }
            if let registrationError {
                Text(registrationError).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stopCapture() }
    }

    private func startCapture() {
        stopCapture()
        capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // esc
                stopCapture()
                return nil
            }
            if let captured = ShortcutTranslator.shortcut(from: event) {
                shortcut = captured
                stopCapture()
                return nil
            }
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = false
    }
}
