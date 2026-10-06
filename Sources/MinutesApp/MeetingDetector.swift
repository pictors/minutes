import AppKit
import Foundation
import MinutesCore

/// 会議アプリの起動・終了とカレンダーから「会議中らしさ」を判定する（SPEC §6.2）。
/// 音声レベルの判定は MeetingSessionController が行う。
@MainActor
final class MeetingDetector {
    var targetBundleIdentifiers: [String] = []
    var onTargetLaunched: ((NSRunningApplication) -> Void)?
    var onTargetTerminated: ((NSRunningApplication) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.handleLaunch(app) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.handleTermination(app) }
        })
    }

    func stop() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
    }

    func isTargetRunning() -> Bool {
        !runningTargets().isEmpty
    }

    func runningTargets() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { BundleIDMatcher.matches($0.bundleIdentifier, targets: targetBundleIdentifiers) && $0.bundleIdentifier?.contains(".helper") != true }
    }

    private func handleLaunch(_ app: NSRunningApplication) {
        guard BundleIDMatcher.matches(app.bundleIdentifier, targets: targetBundleIdentifiers) else { return }
        onTargetLaunched?(app)
    }

    private func handleTermination(_ app: NSRunningApplication) {
        guard BundleIDMatcher.matches(app.bundleIdentifier, targets: targetBundleIdentifiers) else { return }
        // helper の終了は無視し、本体の終了だけを見る
        guard app.bundleIdentifier?.lowercased().contains(".helper") != true else { return }
        onTargetTerminated?(app)
    }
}
