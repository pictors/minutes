import Foundation

public enum TaskDrain {
    /// 子処理がキャンセルに応じなくても、録音セッションの停止をブロックしない。
    public static func wait(_ tasks: [Task<Void, Never>], timeout: Duration) async {
        guard !tasks.isEmpty else { return }
        let (stream, completion) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let waiter = Task {
            for task in tasks { await task.value }
            completion.yield(())
            completion.finish()
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            completion.yield(())
            completion.finish()
        }
        for await _ in stream { break }
        timer.cancel()
        waiter.cancel()
        for task in tasks { task.cancel() }
        completion.finish()
    }
}
