import Darwin
import Foundation

/// 自プロセスの CPU 使用率と常駐メモリ（G7: 録音中 CPU 平均 20% 未満の計測用）。
public struct ProcessResourceUsage: Sendable {
    /// 1 コア基準の CPU 使用率（%）。前回サンプルからの差分で算出。
    public let cpuPercent: Double
    /// 常駐メモリ（bytes）。
    public let residentBytes: UInt64

    public struct Sampler: Sendable {
        private var lastCPUSeconds: Double
        private var lastWall: Double

        public init() {
            lastCPUSeconds = Sampler.cpuSeconds()
            lastWall = HostClock.nowSeconds()
        }

        /// 前回呼び出しからの平均 CPU 使用率を返す。
        public mutating func sample() -> ProcessResourceUsage {
            let cpu = Sampler.cpuSeconds()
            let wall = HostClock.nowSeconds()
            let dt = max(wall - lastWall, 1e-6)
            let percent = (cpu - lastCPUSeconds) / dt * 100
            lastCPUSeconds = cpu
            lastWall = wall
            return ProcessResourceUsage(cpuPercent: max(0, percent), residentBytes: Sampler.residentBytes())
        }

        static func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
            return user + sys
        }

        static func residentBytes() -> UInt64 {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
        }
    }
}

/// スレッドごとの CPU 使用率（G7 の内訳の診断用）。スレッド名でまとめ、前回からの差分を 1 コア基準の % で出す。
/// 画面は "main"、Core Audio の入出力は "com.apple.audio.IOThread.client" などの名前で出る。名前のない作業スレッド（GCD・Swift の並行処理）は "unnamed"。
public struct ThreadCPUSampler: Sendable {
    private var last: [UInt64: Double] = [:]
    private var lastWall = 0.0

    public init() {}

    /// 前回からの使用率を名前ごとに返す（多い順に `limit` 件、0.5% 未満は省く）。初回は基準を取るだけで空を返す。
    public mutating func sample(limit: Int = 6) -> [String: Double] {
        let wall = HostClock.nowSeconds()
        let threads = Self.threadTimes()
        defer {
            last = Dictionary(threads.map { ($0.id, $0.cpuSeconds) }, uniquingKeysWith: { $1 })
            lastWall = wall
        }
        guard lastWall > 0 else { return [:] }
        let elapsed = max(wall - lastWall, 1e-6)
        var byName: [String: Double] = [:]
        for thread in threads {
            // 前回のあとに生まれたスレッドは、生まれてからの時間がすべて今回の区間に入る
            let delta = thread.cpuSeconds - (last[thread.id] ?? 0)
            byName[thread.name, default: 0] += max(0, delta) / elapsed * 100
        }
        let top = byName.filter { $0.value >= 0.5 }.sorted { $0.value > $1.value }.prefix(limit)
        return Dictionary(top.map { ($0.key, ($0.value * 10).rounded() / 10) }, uniquingKeysWith: { $1 })
    }

    private struct ThreadTime {
        var id: UInt64
        var name: String
        var cpuSeconds: Double
    }

    private static func threadTimes() -> [ThreadTime] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return [] }
        defer {
            for index in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[index]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        guard count > 0 else { return [] }
        // task_threads の先頭はプロセスの最初のスレッド（= メインスレッド）。pthread_main_thread_np は Swift から使えない。
        let mainThread = list[0]
        var result: [ThreadTime] = []
        for index in 0..<Int(count) {
            let thread = list[index]
            var basic = thread_basic_info()
            var basicCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &basicCount)
                }
            }
            guard basicResult == KERN_SUCCESS else { continue }
            let cpu = Double(basic.user_time.seconds) + Double(basic.user_time.microseconds) / 1e6
                + Double(basic.system_time.seconds) + Double(basic.system_time.microseconds) / 1e6
            var identifier = thread_identifier_info()
            var identifierCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<natural_t>.size)
            let identifierResult = withUnsafeMutablePointer(to: &identifier) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(identifierCount)) {
                    thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identifierCount)
                }
            }
            let id = identifierResult == KERN_SUCCESS ? identifier.thread_id : UInt64(thread)
            var name = "unnamed"
            if thread == mainThread {
                name = "main"
            } else if let pthread = pthread_from_mach_thread_np(thread) {
                var buffer = [CChar](repeating: 0, count: 64)
                if pthread_getname_np(pthread, &buffer, buffer.count) == 0, buffer[0] != 0 {
                    name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            result.append(ThreadTime(id: id, name: name, cpuSeconds: cpu))
        }
        return result
    }
}
