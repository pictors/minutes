import AppKit
import CoreAudio
import Darwin
import Foundation

/// Core Audio に登録されているプロセス（HAL クライアント）の情報。
public struct AudioProcessInfo: Sendable, Hashable, Codable {
    // convertFromSnakeCase は ID/PID を Id/Pid に変換する。実録音の非空リストも往復可能にする。
    enum CodingKeys: String, CodingKey {
        case objectID = "objectId"
        case pid
        case bundleID = "bundleId"
        case name
        case parentPID = "parentPid"
        case isRunningOutput, isRunningInput
    }

    public var objectID: UInt32
    public var pid: Int32
    public var bundleID: String?
    public var name: String?
    public var parentPID: Int32?
    public var isRunningOutput: Bool
    public var isRunningInput: Bool

    public init(objectID: UInt32, pid: Int32, bundleID: String?, name: String?, parentPID: Int32?, isRunningOutput: Bool, isRunningInput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.parentPID = parentPID
        self.isRunningOutput = isRunningOutput
        self.isRunningInput = isRunningInput
    }
}

/// bundle id のマッチ規則: 完全一致、または `<target>.` で始まる（Chrome の helper など）。
public enum BundleIDMatcher {
    public static func matches(_ bundleID: String?, target: String) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if bundleID.caseInsensitiveCompare(target) == .orderedSame { return true }
        return bundleID.lowercased().hasPrefix(target.lowercased() + ".")
    }

    public static func matches(_ bundleID: String?, targets: [String]) -> Bool {
        targets.contains { matches(bundleID, target: $0) }
    }
}

/// sysctl でプロセスツリーを読む（親 PID 追跡用）。
public enum ProcessTree {
    public struct Entry: Sendable, Hashable {
        public var pid: Int32
        public var parentPID: Int32
        public var name: String
    }

    public static func all() -> [Entry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = buffer.count * stride
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let count = size / stride
        return buffer[0..<count].map { proc in
            let comm = proc.kp_proc.p_comm
            let commSize = MemoryLayout.size(ofValue: comm)
            let name = withUnsafePointer(to: comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: commSize) { String(cString: $0) }
            }
            return Entry(pid: proc.kp_proc.p_pid, parentPID: proc.kp_eproc.e_ppid, name: name)
        }
    }

    public static func byPID() -> [Int32: Entry] {
        var map: [Int32: Entry] = [:]
        for entry in all() { map[entry.pid] = entry }
        return map
    }

    /// pid から親方向に最大 `depth` 段の祖先 PID を返す（自身は含まない）。
    public static func ancestors(of pid: Int32, in table: [Int32: Entry], depth: Int = 6) -> [Int32] {
        var result: [Int32] = []
        var current = pid
        for _ in 0..<depth {
            guard let entry = table[current], entry.parentPID > 1, entry.parentPID != current else { break }
            result.append(entry.parentPID)
            current = entry.parentPID
        }
        return result
    }
}

/// Core Audio のプロセス一覧と、bundle id からの録音対象解決。
@available(macOS 15.0, *)
public enum AudioProcessList {
    public static func all() throws -> [AudioProcessInfo] {
        let system = AudioHardwareSystem.shared
        let table = ProcessTree.byPID()
        var result: [AudioProcessInfo] = []
        for process in try system.processes {
            guard let pid = try? process.pid else { continue }
            let bundleID = (try? process.bundleID).flatMap { $0.isEmpty ? nil : $0 }
            let running = NSRunningApplication(processIdentifier: pid)
            result.append(AudioProcessInfo(
                objectID: process.id,
                pid: pid,
                bundleID: bundleID ?? running?.bundleIdentifier,
                name: running?.localizedName ?? table[pid]?.name,
                parentPID: table[pid]?.parentPID,
                isRunningOutput: (try? process.isRunningOutput) ?? false,
                isRunningInput: (try? process.isRunningInput) ?? false
            ))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// 対象アプリのうち、いま音を出しているかマイクを使っているもの（`rankActiveTargets` の順）。
    /// 音の入出力はブラウザなら helper が持つので、祖先のアプリまでたどって対象に結びつける。
    public static func activeTargets(_ targets: [String]) throws -> [String] {
        guard !targets.isEmpty else { return [] }
        let table = ProcessTree.byPID()
        let active = try all().filter { $0.isRunningOutput || $0.isRunningInput }
        return rankActiveTargets(targets, processes: active) { pid in
            ProcessTree.ancestors(of: pid, in: table).compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        }
    }

    /// 音を出している・マイクを使っている対象を、入出力の両方（通話中らしい）→ 出力だけ → 入力だけの順に並べる。
    /// 同じ順位なら `targets` の順。どちらも使っていない対象は含めない。`ancestorBundleIDs` は pid の祖先アプリの bundle id。
    public static func rankActiveTargets(_ targets: [String], processes: [AudioProcessInfo], ancestorBundleIDs: (Int32) -> [String]) -> [String] {
        var scores: [String: Int] = [:]
        for process in processes {
            let score = switch (process.isRunningOutput, process.isRunningInput) {
            case (true, true): 3
            case (true, false): 2
            case (false, true): 1
            case (false, false): 0
            }
            guard score > 0 else { continue }
            let target = targets.first { BundleIDMatcher.matches(process.bundleID, target: $0) }
                ?? ancestorBundleIDs(process.pid).lazy.compactMap { ancestor in targets.first { BundleIDMatcher.matches(ancestor, target: $0) } }.first
            guard let target else { continue }
            scores[target] = max(scores[target] ?? 0, score)
        }
        return targets.enumerated()
            .filter { scores[$0.element] != nil }
            .sorted { (scores[$0.element]!, -$0.offset) > (scores[$1.element]!, -$1.offset) }
            .map(\.element)
    }

    /// 対象 bundle id に属するプロセス（本体・helper・子プロセス）を解決する。
    /// 1. Core Audio のプロセス一覧から bundle id（前方一致）で選ぶ
    /// 2. 祖先プロセスが対象アプリならその helper も含める
    /// 3. 対象アプリの PID とその子孫について TranslatePIDToProcessObject を試す
    public static func resolve(targets: [String]) throws -> [AudioProcessInfo] {
        guard !targets.isEmpty else { return [] }
        let system = AudioHardwareSystem.shared
        let table = ProcessTree.byPID()
        let everything = try all()
        var selected: [UInt32: AudioProcessInfo] = [:]

        func appBundleID(for pid: Int32) -> String? {
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }

        for info in everything {
            if BundleIDMatcher.matches(info.bundleID, targets: targets) {
                selected[info.objectID] = info
                continue
            }
            for ancestor in ProcessTree.ancestors(of: info.pid, in: table) {
                if BundleIDMatcher.matches(appBundleID(for: ancestor), targets: targets) {
                    selected[info.objectID] = info
                    break
                }
            }
        }

        // 対象アプリの PID と子孫を直接変換する（一覧に出てこない場合の保険）
        var targetPIDs: Set<Int32> = []
        for target in targets {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: target) {
                targetPIDs.insert(app.processIdentifier)
            }
            for app in NSWorkspace.shared.runningApplications where BundleIDMatcher.matches(app.bundleIdentifier, target: target) {
                targetPIDs.insert(app.processIdentifier)
            }
        }
        var candidates = targetPIDs
        for entry in table.values {
            if ProcessTree.ancestors(of: entry.pid, in: table).contains(where: { targetPIDs.contains($0) }) {
                candidates.insert(entry.pid)
            }
        }
        for pid in candidates {
            guard let process = try? system.process(for: pid), selected[process.id] == nil else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            selected[process.id] = AudioProcessInfo(
                objectID: process.id,
                pid: pid,
                bundleID: (try? process.bundleID).flatMap { $0.isEmpty ? nil : $0 } ?? running?.bundleIdentifier,
                name: running?.localizedName ?? table[pid]?.name,
                parentPID: table[pid]?.parentPID,
                isRunningOutput: (try? process.isRunningOutput) ?? false,
                isRunningInput: (try? process.isRunningInput) ?? false
            )
        }
        return selected.values.sorted { $0.pid < $1.pid }
    }
}
