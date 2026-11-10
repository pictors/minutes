import Foundation

/// 更新の再起動を、録音と後処理が終わるまで待たせる（SPEC §6.4）。Sparkle が再起動の前に聞く「遅らせるか」に答え、
/// 遅らせた再起動を続けるときを決める（UI から切り離してテストする）。
/// 忙しくなくなってから `settle` のあいだ空いていたら続ける（録音が終わった直後は、後処理の依頼が始まる前で空いて見える）。
@MainActor
public final class RelaunchGate {
    public private(set) var isBusy = false
    /// 遅らせている再起動の続き（Sparkle から預かる）。
    private var pending: (() -> Void)?
    private var resumeTask: Task<Void, Never>?
    private let settle: Duration

    public init(settle: Duration = .seconds(3)) {
        self.settle = settle
    }

    public var isPostponed: Bool { pending != nil }

    /// 再起動してよいか聞かれた。忙しければ続きを預かって true（遅らせる）を返す。
    public func shouldPostpone(_ resume: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        pending = resume
        return true
    }

    /// 録音中・後処理の実行中か。空いたら、空いたままのときだけ `settle` のあとで遅らせた再起動を続ける。
    public func setBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        resumeTask?.cancel()
        resumeTask = nil
        guard !busy, pending != nil else { return }
        let settle = settle
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, let self, !self.isBusy, let resume = self.pending else { return }
            self.pending = nil
            self.resumeTask = nil
            resume()
        }
    }
}
