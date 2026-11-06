import Foundation
import Synchronization

/// 録音の入力（tap・マイク）を別々のスレッドで並べて止め、決めた時間だけ待つ。
/// 入力の停止は Core Audio・AVAudioEngine の中で戻らないことがある（機器の作り直しの途中に蓋を閉じると、Mac が次に起きるまで）。
/// 録音の停止がそれを待ち続けると、ファイルを閉じられず、会議の状態も進まない。
/// 待ちきれなかった停止はそのまま続け、戻ったところで入力を閉じる。並べて止めるので、片方が戻らなくてももう片方は止まる。
enum CaptureStop {
    struct Input: Sendable {
        var name: String
        var stop: @Sendable () -> Void
    }

    /// `timeout` 秒のうちに止まらなかった入力の名前を、渡した順に返す。
    static func run(_ inputs: [Input], timeout: TimeInterval) -> [String] {
        let stopped = Mutex<Set<String>>([])
        let group = DispatchGroup()
        for input in inputs {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                input.stop()
                stopped.withLock { _ = $0.insert(input.name) }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        let done = stopped.withLock { $0 }
        return inputs.map(\.name).filter { !done.contains($0) }
    }
}
