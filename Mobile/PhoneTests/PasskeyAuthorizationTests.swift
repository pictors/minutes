import AuthenticationServices
import XCTest
@testable import Minutes

/// パスキー（SPEC §5.7）: この iPhone だけのパスキーを求めて断られたとき、パスキーがなかったのか・閉じたのかの見分け方と、画面に出す言葉。
/// 手元のサーバーは要らない。
final class PasskeyAuthorizationTests: XCTestCase {
    /// iOS 26.5 のシミュレータで、パスキーがないときに返った理由
    private let noCredentials = "No credentials available for login."

    func testNoPasskeyWhenRefusedImmediately() {
        // 理由の文言があれば、時間によらず「ない」（重い端末で遅れても）
        XCTAssertTrue(PasskeyAuthorization.foundNoPasskey(.canceled, failureReason: noCredentials, elapsed: .milliseconds(400)))
        XCTAssertTrue(PasskeyAuthorization.foundNoPasskey(.canceled, failureReason: noCredentials, elapsed: .seconds(3)))
        // 文言が変わっても、画面を出して閉じるには短すぎる時間で断られたら「ない」
        XCTAssertTrue(PasskeyAuthorization.foundNoPasskey(.canceled, failureReason: nil, elapsed: .milliseconds(300)))
        XCTAssertTrue(PasskeyAuthorization.foundNoPasskey(.notInteractive, failureReason: nil, elapsed: .seconds(2)))
    }

    func testCancelAfterSheetIsNotMissingPasskey() {
        // 画面を出したあとに利用者が閉じた: 何も出さない
        XCTAssertFalse(PasskeyAuthorization.foundNoPasskey(.canceled, failureReason: nil, elapsed: .seconds(1)))
        XCTAssertFalse(PasskeyAuthorization.foundNoPasskey(.canceled, failureReason: nil, elapsed: .seconds(4)))
    }

    func testOtherFailuresAreNotMissingPasskey() {
        // 関連ドメインが合わないなどの失敗は、そのまま誤りとして出す
        for code: ASAuthorizationError.Code in [.failed, .invalidResponse, .notHandled, .unknown, .matchedExcludedCredential] {
            XCTAssertFalse(PasskeyAuthorization.foundNoPasskey(code, failureReason: noCredentials, elapsed: .milliseconds(100)), "\(code.rawValue)")
        }
    }

    @MainActor
    func testCancellationAndMessages() {
        XCTAssertTrue(PasskeyAuthorization.isCancellation(ASAuthorizationError(.canceled)))
        XCTAssertTrue(PasskeyAuthorization.isCancellation(CancellationError()))
        XCTAssertFalse(PasskeyAuthorization.isCancellation(PasskeyFailure.noPasskeyOnDevice))
        XCTAssertEqual(PasskeyAuthorization.message(for: PasskeyFailure.noPasskeyOnDevice), "この iPhone には、まだ Minutes のパスキーがありません")
        XCTAssertEqual(PasskeyAuthorization.message(for: ASAuthorizationError(.notInteractive)), "この iPhone には、まだ Minutes のパスキーがありません")
        XCTAssertEqual(PasskeyAuthorization.message(for: ASAuthorizationError(.matchedExcludedCredential)), "この Apple アカウントには、もうこのアカウントのパスキーがあります")
    }
}
