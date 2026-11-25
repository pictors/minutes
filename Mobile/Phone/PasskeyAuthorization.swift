import AuthenticationServices
import MinutesKit
import os
import UIKit

/// パスキーを作る・確かめる（ASAuthorizationPlatformPublicKeyCredentialProvider。RP は minutes.tools、関連ドメインは
/// webcredentials:minutes.tools。minutes.tools の .well-known/apple-app-site-association がこのアプリを挙げている）。
/// パスキーは iCloud キーチェーンに入り、同じ Apple アカウントのほかの端末にも届く。
@MainActor
final class PasskeyAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?
    private static let log = Logger(subsystem: "jp.pictors.minutes", category: "passkey")

    /// パスキーを作る（サーバーの準備をそのまま渡す。同じアカウントのパスキーがこの Apple アカウントにあれば、iOS が断る）
    func register(_ options: MinutesCloudPasskeyCreationOptions) async throws -> MinutesCloudPasskeyRegistration {
        guard let challenge = options.challengeData, let userID = options.userIDData else { throw PasskeyFailure.badOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingPartyID)
        let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: options.user.name, userID: userID)
        request.excludedCredentials = options.excludedCredentialIDs.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        request.userVerificationPreference = Self.preference(options.authenticatorSelection?.userVerification)
        request.attestationPreference = .none
        let authorization = try await perform(request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestationObject = credential.rawAttestationObject
        else { throw PasskeyFailure.unexpectedCredential }
        return MinutesCloudPasskeyRegistration(
            credentialID: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON,
            attestationObject: attestationObject,
            attachment: Self.attachment(credential.attachment)
        )
    }

    /// パスキーで確かめる（この端末にあるパスキーから選ぶ。iCloud キーチェーンで同期したものも含む）。
    /// 使えるパスキーがこの端末にないとき、iOS はほかの端末のパスキーを使う QR を出すが、それは出さずに
    /// PasskeyFailure.noPasskeyOnDevice を投げる（作り方を案内する）。あるときのシートからは、ほかの端末のパスキーも選べる。
    func assert(_ options: MinutesCloudPasskeyRequestOptions) async throws -> MinutesCloudPasskeyAssertion {
        guard let challenge = options.challengeData else { throw PasskeyFailure.badOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        let allowed = (options.allowCredentials ?? []).compactMap(\.idData)
        if !allowed.isEmpty { request.allowedCredentials = allowed.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) } }
        request.userVerificationPreference = Self.preference(options.userVerification)
        let authorization = try await perform(request, onlyOnThisDevice: true)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { throw PasskeyFailure.unexpectedCredential }
        let authenticatorData: Data? = credential.rawAuthenticatorData
        let signature: Data? = credential.signature
        let userHandle: Data? = credential.userID
        guard let authenticatorData, let signature else { throw PasskeyFailure.unexpectedCredential }
        return MinutesCloudPasskeyAssertion(
            credentialID: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON,
            authenticatorData: authenticatorData,
            signature: signature,
            userHandle: userHandle?.isEmpty == false ? userHandle : nil,
            attachment: Self.attachment(credential.attachment)
        )
    }

    /// サーバーにないパスキー（アカウントから外した・アカウントを消した）を、端末のパスキーの一覧から外すよう知らせる（WebAuthn の Signal API）
    static func reportUnknown(credentialID: Data) async {
        try? await ASCredentialUpdater().reportUnknownPublicKeyCredential(relyingPartyIdentifier: MinutesCloudPasskeys.relyingPartyID, credentialID: credentialID)
    }

    /// 利用者が閉じた（何もしない）か。続けて押して前の求めを閉じたときも
    static func isCancellation(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled || error is CancellationError
    }

    /// この端末だけのパスキーを求めて断られたとき、この端末に使えるパスキーがなかったのか。
    /// iOS は、パスキーがないときも利用者が閉じたときも「取り消し」（canceled）を返し、どちらでも画面を出す場所を聞いてくる。
    /// パスキーがないときは画面を出さずにすぐ断り、理由に「No credentials available for login.」を付ける
    /// （2026-11-26、iOS 26.5 のシミュレータで 0.4 秒）。理由の文言か、画面を出して閉じるには短すぎる時間（1 秒未満）なら、ないとみなす。
    nonisolated static func foundNoPasskey(_ code: ASAuthorizationError.Code, failureReason: String?, elapsed: Duration) -> Bool {
        switch code {
        case .notInteractive:
            true
        case .canceled:
            failureReason?.localizedCaseInsensitiveContains("no credentials") == true || elapsed < .seconds(1)
        default:
            false
        }
    }

    /// 画面に出す言葉
    static func message(for error: Error) -> String {
        if let failure = error as? PasskeyFailure { return failure.localizedDescription }
        if let authorization = error as? ASAuthorizationError {
            switch authorization.code {
            case .matchedExcludedCredential:
                return "この Apple アカウントには、もうこのアカウントのパスキーがあります"
            case .notInteractive:
                return PasskeyFailure.noPasskeyOnDevice.localizedDescription
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func preference(_ value: String?) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch value {
        case "required": .required
        case "discouraged": .discouraged
        default: .preferred
        }
    }

    private static func attachment(_ value: ASAuthorizationPublicKeyCredentialAttachment) -> MinutesCloudPasskeyAttachment {
        value == .crossPlatform ? .crossPlatform : .platform
    }

    /// onlyOnThisDevice: この端末にすぐ使えるパスキーがあるときだけ画面を出す（ないときは画面を出さずに断られ、ほかの端末の QR も出さない。
    /// あるときのシートには、iOS の「ほかの端末でサインイン」が残る）
    private func perform(_ request: ASAuthorizationRequest, onlyOnThisDevice: Bool = false) async throws -> ASAuthorization {
        // 前の求めが残っていれば閉じる（続けて 2 回押したとき）
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        let started = ContinuousClock.now
        do {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if onlyOnThisDevice {
                    controller.performRequests(options: .preferImmediatelyAvailableCredentials)
                } else {
                    controller.performRequests()
                }
            }
        } catch let error as ASAuthorizationError where onlyOnThisDevice {
            let elapsed = ContinuousClock.now - started
            let reason = (error as NSError).localizedFailureReason
            let noPasskey = Self.foundNoPasskey(error.code, failureReason: reason, elapsed: elapsed)
            Self.log.debug("assert failed: code \(error.code.rawValue, privacy: .public) elapsed \(elapsed.description, privacy: .public) reason \(reason ?? "-", privacy: .public) -> noPasskey \(noPasskey, privacy: .public)")
            if noPasskey { throw PasskeyFailure.noPasskeyOnDevice }
            throw error
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        MainActor.assumeIsolated {
            continuation?.resume(returning: authorization)
            continuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        MainActor.assumeIsolated {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.compactMap(\.keyWindow).first { return window }
            guard let scene = scenes.first else { preconditionFailure("パスキーの画面を出す場所がない") }
            return UIWindow(windowScene: scene)
        }
    }
}

/// パスキーの失敗（サーバーと iOS の誤りのほか）
enum PasskeyFailure: Error, LocalizedError, Equatable {
    /// サーバーの準備を読めない
    case badOptions
    /// iOS が思っていない形の結果を返した
    case unexpectedCredential
    /// パスキーを作るには、ログインから 1 日以内である必要がある（サーバーの SESSION_NOT_FRESH）
    case needsReauthentication
    /// 確かめ直しで、別の Minutes アカウントに入った
    case differentAccount
    /// この端末に、使える Minutes のパスキーがない（作ったことがない・iCloud キーチェーンを切っている）
    case noPasskeyOnDevice

    var errorDescription: String? {
        switch self {
        case .badOptions: "サーバーからパスキーの準備を読めませんでした"
        case .unexpectedCredential: "パスキーの結果を読めませんでした"
        case .needsReauthentication: "パスキーを作るには、確かめのためにもう一度ログインしてください"
        case .differentAccount: "いまの Minutes アカウントとは別のアカウントでした。いまのアカウントのログインで確かめてください"
        case .noPasskeyOnDevice: "この iPhone には、まだ Minutes のパスキーがありません"
        }
    }
}
