import AuthenticationServices
import MinutesKit
import UIKit

/// パスキーを作る・確かめる（ASAuthorizationPlatformPublicKeyCredentialProvider。RP は minutes.tools、関連ドメインは
/// webcredentials:minutes.tools。minutes.tools の .well-known/apple-app-site-association がこのアプリを挙げている）。
/// パスキーは iCloud キーチェーンに入り、同じ Apple アカウントのほかの端末にも届く。
@MainActor
final class PasskeyAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?
    private var controller: ASAuthorizationController?

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

    /// パスキーで確かめる（端末にあるパスキーから選ぶ。近くのほかの端末のパスキーも使える）
    func assert(_ options: MinutesCloudPasskeyRequestOptions) async throws -> MinutesCloudPasskeyAssertion {
        guard let challenge = options.challengeData else { throw PasskeyFailure.badOptions }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingPartyID)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        let allowed = (options.allowCredentials ?? []).compactMap(\.idData)
        if !allowed.isEmpty { request.allowedCredentials = allowed.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) } }
        request.userVerificationPreference = Self.preference(options.userVerification)
        let authorization = try await perform(request)
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

    /// 利用者が閉じた（何もしない）か
    static func isCancellation(_ error: Error) -> Bool {
        (error as? ASAuthorizationError)?.code == .canceled
    }

    /// 画面に出す言葉
    static func message(for error: Error) -> String {
        if let failure = error as? PasskeyFailure { return failure.localizedDescription }
        if let authorization = error as? ASAuthorizationError {
            switch authorization.code {
            case .matchedExcludedCredential:
                return "この Apple アカウントには、もうこのアカウントのパスキーがあります"
            case .notInteractive:
                return "この iPhone に Minutes のパスキーがありません"
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

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        // 前の求めが残っていれば閉じる（続けて 2 回押したとき）
        continuation?.resume(throwing: ASAuthorizationError(.canceled))
        continuation = nil
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
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

    var errorDescription: String? {
        switch self {
        case .badOptions: "サーバーからパスキーの準備を読めませんでした"
        case .unexpectedCredential: "パスキーの結果を読めませんでした"
        case .needsReauthentication: "パスキーを作るには、確かめのためにもう一度ログインしてください"
        case .differentAccount: "いまの Minutes アカウントとは別のアカウントでした。いまのアカウントのログインで確かめてください"
        }
    }
}
