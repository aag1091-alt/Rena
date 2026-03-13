import AuthenticationServices
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Setup instructions
// 1. Go to Google Cloud Console → APIs & Services → Credentials
// 2. Create an OAuth 2.0 Client ID  →  type: iOS
// 3. Bundle ID: com.rena.app  (match your Xcode target)
// 4. Copy the "Client ID" and "Reversed client ID" below
// 5. Add the reversed client ID as a URL scheme in Info.plist (already done)

private let kGoogleClientID     = "879054433521-rdqeseb320crra6phl9anti84cjvteo1.apps.googleusercontent.com"
private let kGoogleRedirectURI  = "com.googleusercontent.apps.879054433521-rdqeseb320crra6phl9anti84cjvteo1:/oauth2redirect"

// MARK: -

struct GoogleUser {
    let id: String
    let email: String
    let name: String
}

@MainActor
final class GoogleSignInManager: NSObject {
    static let shared = GoogleSignInManager()

    func signIn() async throws -> GoogleUser {
        let verifier = makeCodeVerifier()
        let challenge = makeCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id",             value: kGoogleClientID),
            URLQueryItem(name: "redirect_uri",          value: kGoogleRedirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: "openid profile email"),
            URLQueryItem(name: "code_challenge",        value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]

        let callbackScheme = String(kGoogleRedirectURI.split(separator: ":").first!)
        let code = try await openBrowser(url: components.url!, callbackScheme: callbackScheme)
        return try await exchangeCode(code, verifier: verifier)
    }

    // MARK: - Private

    private func openBrowser(url: URL, callbackScheme: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let callbackURL,
                    let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> GoogleUser {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let params: [String: String] = [
            "code":          code,
            "client_id":     kGoogleClientID,
            "redirect_uri":  kGoogleRedirectURI,
            "grant_type":    "authorization_code",
            "code_verifier": verifier,
        ]
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)

        struct TokenResponse: Codable {
            let idToken: String
            enum CodingKeys: String, CodingKey { case idToken = "id_token" }
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        return try decodeIDToken(tokens.idToken)
    }

    private func decodeIDToken(_ token: String) throws -> GoogleUser {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw URLError(.badServerResponse) }

        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }

        guard let data = Data(base64Encoded: b64) else { throw URLError(.cannotDecodeContentData) }

        struct Claims: Codable {
            let sub: String
            let email: String
            let name: String?
            let givenName: String?
            enum CodingKeys: String, CodingKey {
                case sub, email, name
                case givenName = "given_name"
            }
        }
        let claims = try JSONDecoder().decode(Claims.self, from: data)
        let displayName = claims.givenName ?? claims.name ?? claims.email
        return GoogleUser(id: claims.sub, email: claims.email, name: displayName)
    }

    // MARK: - PKCE helpers

    private func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeCodeChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension GoogleSignInManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
