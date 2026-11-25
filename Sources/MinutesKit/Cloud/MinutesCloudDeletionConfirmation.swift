import Foundation

/// アカウントを消す前に打ち込んでもらう文字（押し間違えで消さないため）。
/// ふつうはログイン中のメールアドレス（どのアカウントを消すのかも確かめられる）。
/// Apple の「メールを非公開」のアドレス（打ちにくい）か、アドレスが分からないときは「削除」。
/// 「削除」は、かなのまま（さくじょ）と、英字のキーボードの delete でもよい（日本語のキーボードがない人も消せるように）。
public struct MinutesCloudDeletionConfirmation: Equatable, Sendable {
    public enum Expected: Equatable, Sendable {
        case email(String)
        case word
    }

    /// アドレスの代わりに打ち込む言葉
    public static let word = "削除"
    /// 英字のキーボードで打つときの言葉
    public static let asciiWord = "delete"
    private static let acceptedWords: Set<String> = [word, "さくじょ", asciiWord]

    public let expected: Expected

    public init(user: MinutesCloudUser?) {
        let email = user?.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if email.contains("@"), user?.isApplePrivateRelay != true {
            expected = .email(email)
        } else {
            expected = .word
        }
    }

    /// 打ち込んだ文字が合っているか。前後の空白は見ず、メールアドレスは大文字と小文字を区別しない。空はいつも合わない
    public func matches(_ typed: String) -> Bool {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        switch expected {
        case let .email(email):
            return value.lowercased() == email.lowercased()
        case .word:
            return Self.acceptedWords.contains(value.lowercased())
        }
    }
}
