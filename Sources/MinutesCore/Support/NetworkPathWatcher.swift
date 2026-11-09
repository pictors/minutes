import Foundation
import Network
import Synchronization

/// 回線がつながっているかを見張り、つながったときに知らせる（SPEC §8.2。回線を待っている後処理を再開する）。
/// 確認済み（Xcode 26 の SDK の Network の swiftinterface）: `NWPathMonitor()`、`pathUpdateHandler`、`start(queue:)`、
/// `cancel()`、`NWPath.status` の `.satisfied`。
public final class NetworkPathWatcher: Sendable {
    private struct State {
        /// 最初の知らせが届くまでは、つながっているとみなす（待たせない）。
        var available = true
        var handlers: [@Sendable () -> Void] = []
    }

    private let monitor: NWPathMonitor
    private let state = Mutex(State())

    public init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let available = path.status == .satisfied
            let handlers = state.withLock { state -> [@Sendable () -> Void] in
                let connected = available && !state.available
                state.available = available
                return connected ? state.handlers : []
            }
            for handler in handlers { handler() }
        }
        monitor.start(queue: DispatchQueue(label: "jp.pictors.minutes.network-path"))
    }

    deinit { monitor.cancel() }

    public var isAvailable: Bool { state.withLock { $0.available } }

    /// 回線が切れていた状態からつながったときに呼ぶ処理を足す。
    public func onAvailable(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.handlers.append(handler) }
    }
}
