import Foundation
import Synchronization

/// 統計を表示する呼び出し元がなくても、録音中の入力停止を検知する。
/// 片方のトラックだけが止まったときは録音を続け、途切れと復帰を知らせる（SPEC §4.3）。
/// すべてのトラックが止まったときだけ失敗にする。
final class CaptureWatchdog: Sendable {
    /// これより長く音声が届かないトラックを「途切れ」とみなす。
    static let stallSeconds: Double = 5

    enum Interruption: Sendable, Equatable {
        /// `since` は最後に届いた音声の末尾（録音タイムラインの秒）。
        case interrupted(track: String, since: Double)
        /// `seconds` は途切れていたおよその長さ（監視間隔ぶん長めに出る）。
        case recovered(track: String, seconds: Double)
    }

    private let timer: DispatchSourceTimer
    private let active = Mutex(true)
    /// 途切れているトラック → 最後に届いた音声の末尾。
    private let stalled = Mutex<[String: Double]>([:])

    init(startTime: Double, tapAutoStart: Bool, interval: TimeInterval = 1,
         now: @escaping @Sendable () -> Double = { HostClock.nowSeconds() },
         snapshots: @escaping @Sendable () -> [TrackStatsSnapshot],
         onInterruption: @escaping @Sendable (Interruption) -> Void = { _ in },
         onFailure: @escaping @Sendable (CaptureFailure) -> Void) {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "jp.pictors.minutes.capture.watchdog"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, self.active.withLock({ $0 }) else { return }
            let stats = snapshots()
            guard self.active.withLock({ $0 }) else { return }
            self.check(stats, elapsed: now() - startTime, tapAutoStart: tapAutoStart, onInterruption: onInterruption, onFailure: onFailure)
        }
        timer.resume()
    }

    /// 途切れているトラック（"system" / "mic"）。画面の警告用。
    var interruptedTracks: [String] { stalled.withLock { $0.keys.sorted() } }

    /// 1 回分の判定（タイマーから呼ぶ。テストでは直接呼ぶ）。
    func check(_ stats: [TrackStatsSnapshot], elapsed: Double, tapAutoStart: Bool,
               onInterruption: @Sendable (Interruption) -> Void, onFailure: @Sendable (CaptureFailure) -> Void) {
        let stalledNames = Set(stats.filter { Self.isStalled(stats: $0, elapsed: elapsed, tapAutoStart: tapAutoStart) }.map(\.name))
        if !stats.isEmpty, stalledNames.count == stats.count {
            onFailure(Self.failure(stalled: stats))
            stop()
            return
        }
        var events: [Interruption] = []
        stalled.withLock { current in
            for track in stats {
                if stalledNames.contains(track.name) {
                    guard current[track.name] == nil else { continue }
                    let since = track.lastChunkTimelineEnd ?? 0
                    current[track.name] = since
                    events.append(.interrupted(track: track.name, since: since))
                } else if let since = current.removeValue(forKey: track.name) {
                    events.append(.recovered(track: track.name, seconds: max(0, elapsed - since)))
                }
            }
        }
        for event in events { onInterruption(event) }
    }

    static func isStalled(stats: TrackStatsSnapshot, elapsed: Double, tapAutoStart: Bool) -> Bool {
        if stats.name == "system", tapAutoStart, stats.lastChunkTimelineEnd == nil { return false }
        return elapsed - (stats.lastChunkTimelineEnd ?? 0) > stallSeconds
    }

    static func failure(stalled stats: [TrackStatsSnapshot]) -> CaptureFailure {
        let message = stats.count > 1
            ? "すべての音声入力が \(Int(stallSeconds)) 秒以上届いていません。接続を確認してください。"
            : "音声データが \(Int(stallSeconds)) 秒以上届いていません。接続を確認してください。"
        return CaptureFailure(track: stats.first?.name ?? "system", operation: "音声入力の監視", message: message)
    }

    func stop() {
        active.withLock { $0 = false }
        timer.cancel()
    }

    deinit { timer.cancel() }
}
