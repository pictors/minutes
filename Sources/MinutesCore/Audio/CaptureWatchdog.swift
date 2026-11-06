import Foundation
import Synchronization

/// 統計を表示する呼び出し元がなくても、録音中の入力停止を検知する。
/// 片方のトラックだけが止まったときは録音を続け、途切れと復帰を知らせる（SPEC §4.3）。
/// すべてのトラックが止まったときだけ失敗にする。
final class CaptureWatchdog: Sendable {
    /// これより長く音声が届かないトラックを「途切れ」とみなす。
    static let stallSeconds: Double = 5
    /// 監視が録音を止めたときの `CaptureFailure.operation`。古い recording.json もこの値で見分ける（`isInputStall`）。
    static let failureOperation = "音声入力の監視"

    enum Interruption: Sendable, Equatable {
        /// `since` は最後に届いた音声の末尾（録音タイムラインの秒）。
        case interrupted(track: String, since: Double)
        /// `seconds` は途切れていたおよその長さ（監視間隔ぶん長めに出る）。
        case recovered(track: String, seconds: Double)
    }

    private let timer: DispatchSourceTimer
    private let active = Mutex(true)
    private let startTime: Double
    private let now: @Sendable () -> Double
    /// 途切れているトラック → 最後に届いた音声の末尾。
    private let stalled = Mutex<[String: Double]>([:])
    /// 入力を作り直したトラック → 作り直した時刻（録音タイムラインの秒）。
    private let restarts = Mutex<[String: Double]>([:])

    init(startTime: Double, tapAutoStart: Bool, interval: TimeInterval = 1,
         now: @escaping @Sendable () -> Double = { HostClock.nowSeconds() },
         snapshots: @escaping @Sendable () -> [TrackStatsSnapshot],
         onInterruption: @escaping @Sendable (Interruption) -> Void = { _ in },
         onFailure: @escaping @Sendable (CaptureFailure) -> Void) {
        self.startTime = startTime
        self.now = now
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

    /// 機器の切り替えで入力（tap / マイク）を作り直せたことを知らせる。作り直している間は音声が届かないので、
    /// そのトラックは作り直した時刻から、ふだんと同じ 5 秒で数え直す。切り替え前の最後の音声から数えると、
    /// 両トラックが同時に作り直しになっただけで録音全体が失敗になる。
    /// 作り直しを求めた時点から猶予を置く方法は採らない: 作り直しに失敗して再試行している間（停止まで続く）も
    /// 猶予が続き、入力が戻らないことを見逃すため。作り直せたときだけ呼ぶ。
    func noteRestart(track: String) {
        noteRestart(track: track, at: now() - startTime)
    }

    /// `elapsed` は録音タイムラインの秒（テストでは直接渡す）。
    func noteRestart(track: String, at elapsed: Double) {
        restarts.withLock { $0[track] = elapsed }
    }

    /// 1 回分の判定（タイマーから呼ぶ。テストでは直接呼ぶ）。
    func check(_ stats: [TrackStatsSnapshot], elapsed: Double, tapAutoStart: Bool,
               onInterruption: @Sendable (Interruption) -> Void, onFailure: @Sendable (CaptureFailure) -> Void) {
        let restartedAt = restarts.withLock { $0 }
        let stalledNames = Set(stats.filter {
            Self.isStalled(stats: $0, elapsed: elapsed, tapAutoStart: tapAutoStart, restartedAt: restartedAt[$0.name])
        }.map(\.name))
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
                } else if let since = current[track.name], (track.lastChunkTimelineEnd ?? 0) > since {
                    // 作り直して数え直しただけでは戻ったとみなさない（画面の警告と復帰の記録は、音声が届いてから）。
                    current.removeValue(forKey: track.name)
                    events.append(.recovered(track: track.name, seconds: max(0, elapsed - since)))
                }
            }
        }
        for event in events { onInterruption(event) }
    }

    /// `restartedAt` はそのトラックの入力を最後に作り直した時刻。最後の音声より後なら、そこから数える。
    static func isStalled(stats: TrackStatsSnapshot, elapsed: Double, tapAutoStart: Bool, restartedAt: Double? = nil) -> Bool {
        if stats.name == "system", tapAutoStart, stats.lastChunkTimelineEnd == nil { return false }
        let since = max(stats.lastChunkTimelineEnd ?? 0, restartedAt ?? 0)
        return elapsed - since > stallSeconds
    }

    static func failure(stalled stats: [TrackStatsSnapshot]) -> CaptureFailure {
        let message = stats.count > 1
            ? "すべての音声入力が \(Int(stallSeconds)) 秒以上届いていません。接続を確認してください。"
            : "音声データが \(Int(stallSeconds)) 秒以上届いていません。接続を確認してください。"
        return CaptureFailure(track: stats.first?.name ?? "system", operation: failureOperation, message: message)
    }

    func stop() {
        active.withLock { $0 = false }
        timer.cancel()
    }

    deinit { timer.cancel() }
}

extension CaptureFailure {
    /// 監視が「音声が届かない」と判断して録音を止めた失敗。書き込み・変換・時計の失敗（`TrackPipeline`）と違い、
    /// 止まるまでに書いたファイルは正常なので、後処理は長さの照合が通れば進める。
    public var isInputStall: Bool { operation == CaptureWatchdog.failureOperation }
}
