import Foundation

/// 処理のあいだに Mac がスリープしていたかを測る（SPEC §8.2）。
/// 確認済み（Xcode 26 の SDK の _Concurrency の swiftdoc）: `ContinuousClock` は「スリープ中も止まらずに進む」、
/// `SuspendingClock` は「スリープ中は進まない」。二つの経過時間の差が、スリープしていた時間になる。
public struct SleepWatch: Sendable {
    private let continuousStart: ContinuousClock.Instant
    private let suspendingStart: SuspendingClock.Instant

    public init() {
        continuousStart = .now
        suspendingStart = .now
    }

    /// 測り始めてからスリープしていた秒数。
    public var sleptSeconds: Double {
        let continuous = continuousStart.duration(to: .now)
        let suspending = suspendingStart.duration(to: .now)
        return max(0, Self.seconds(continuous - suspending))
    }

    static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// 後処理がスリープを見張る方法（テストで差し替える）。
public struct SleepMonitor: Sendable {
    /// 呼ぶと測り始め、返した関数がそれまでにスリープしていた秒数を返す。
    public var start: @Sendable () -> @Sendable () -> Double
    /// 送信中にスリープを挟んだかを確かめる間隔。起きている時間（`SuspendingClock`）で数える。
    public var checkInterval: Duration
    /// これより長く眠っていたら、スリープで中断したとみなす（秒）。
    public var threshold: Double

    public init(start: @escaping @Sendable () -> @Sendable () -> Double, checkInterval: Duration, threshold: Double) {
        self.start = start
        self.checkInterval = checkInterval
        self.threshold = threshold
    }

    public static let system = SleepMonitor(
        start: {
            let watch = SleepWatch()
            return { watch.sleptSeconds }
        },
        checkInterval: .seconds(10),
        threshold: 10
    )
}
