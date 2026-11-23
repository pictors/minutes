import CryptoKit
import Foundation

/// Sign in with Apple の nonce（製品版の P4）。生の nonce はサーバーへ、SHA-256（16 進、小文字）は Apple の要求
/// （ASAuthorizationAppleIDRequest.nonce）へ渡す。サーバーは identity token の nonce が生の nonce の SHA-256 であることと、
/// 同じ nonce を二度使っていないことを確かめる（サーバーの README）。
public struct MinutesCloudAppleNonce: Sendable, Equatable {
    /// サーバーへ送る生の nonce
    public let raw: String
    /// Apple の要求に入れる SHA-256 の 16 進
    public let hashed: String

    public init(raw: String) {
        self.raw = raw
        hashed = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 32 バイトの乱数から作る。
    public static func make() -> MinutesCloudAppleNonce {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return MinutesCloudAppleNonce(raw: bytes.map { String(format: "%02x", $0) }.joined())
    }
}
