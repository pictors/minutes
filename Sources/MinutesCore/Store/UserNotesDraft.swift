import Foundation
import Observation

/// 永続データの再取得とユーザーの編集を分離する。会議ごとに保持し、画面の寿命に依存しない。
@MainActor
@Observable
public final class UserNotesDraft {
    public private(set) var text = ""
    public private(set) var isDirty = false
    public private(set) var saveError: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let delay: Duration
    @ObservationIgnored private let save: (String) throws -> Void

    public init(delay: Duration = .milliseconds(800), save: @escaping (String) throws -> Void) {
        self.delay = delay
        self.save = save
    }

    public func receivePersisted(_ text: String) {
        guard !isDirty else { return }
        self.text = text
    }

    /// Binding の setter からのみ呼ぶ。DB の更新では保存予約を作らない。
    public func edit(_ text: String) {
        guard self.text != text else { return }
        self.text = text
        isDirty = true
        saveError = nil
        saveTask?.cancel()
        let delay = delay
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.flush()
        }
    }

    /// 画面離脱・再試行時に即座に保存する。失敗した編集はそのまま保持する。
    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else { return }
        do {
            try save(text)
            isDirty = false
            saveError = nil
        } catch { saveError = "メモを保存できません: \(error.localizedDescription)" }
    }

    public func discard() {
        saveTask?.cancel()
        saveTask = nil
        isDirty = false
    }
}
