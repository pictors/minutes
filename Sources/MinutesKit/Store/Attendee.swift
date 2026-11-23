import Foundation

/// 会議の参加者（予定から取ったもの・手で直したもの）。要約の入力にも入る。
public struct Attendee: Codable, Sendable, Equatable, Hashable {
    public var name: String
    public var email: String?

    public init(name: String, email: String? = nil) {
        self.name = name
        self.email = email
    }
}
