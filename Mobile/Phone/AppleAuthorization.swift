import AuthenticationServices
import MinutesKit
import UIKit

/// Sign in with Apple をボタンなしで頼む（アカウントの削除の直前に、Apple のログインを取り消すための authorization code を取る）。
/// サーバーは code を refresh token に替えて取り消す（refresh token は持たない。2026-11-23 の決定）。
@MainActor
final class AppleAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var controller: ASAuthorizationController?

    func request(nonce: MinutesCloudAppleNonce) async throws -> ASAuthorizationAppleIDCredential {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email]
        request.nonce = nonce.hashed
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
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        MainActor.assumeIsolated {
            if let credential {
                continuation?.resume(returning: credential)
            } else {
                continuation?.resume(throwing: ASAuthorizationError(.failed))
            }
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
            guard let scene = scenes.first else { preconditionFailure("Apple のログインを出す画面がない") }
            return UIWindow(windowScene: scene)
        }
    }
}

extension ASAuthorizationAppleIDCredential {
    var identityTokenString: String? { identityToken.map { String(decoding: $0, as: UTF8.self) } }
    var authorizationCodeString: String? { authorizationCode.map { String(decoding: $0, as: UTF8.self) } }
}
