import Foundation
import Synchronization
import Testing
@testable import MinutesCore

@Suite("録音中の CPU の内訳（G7）")
struct ResourceUsageTests {
    @Test("CPU を使っているスレッドを名前ごとに出す（初回は基準を取るだけ）")
    func threadBreakdown() async throws {
        let running = Mutex(true)
        let worker = Thread {
            var value = 0.0
            while running.withLock({ $0 }) { value += sin(value) }
        }
        worker.name = "minutes.test.busy"
        worker.start()
        defer { running.withLock { $0 = false } }

        var sampler = ThreadCPUSampler()
        #expect(sampler.sample().isEmpty)
        try await Task.sleep(for: .milliseconds(400))
        let usage = sampler.sample(limit: 20)
        // 回り続けるスレッドは 1 コアの大半を使う（CI の混み具合を見込んで下限は低めにする）
        #expect((usage["minutes.test.busy"] ?? 0) > 30)
    }
}
