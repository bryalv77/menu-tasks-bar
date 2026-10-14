import AuthenticationServices
import CryptoKit
import Foundation

struct Tokens: Codable {
    var access: String
    var refresh: String?
    var expiry: Date
}

enum AuthError: LocalizedError {
    case signedOut, cancelled, badCallback, server(String)
    var errorDescription: String? {
        switch self {
        case .signedOut: return "Not signed in."
        case .cancelled: return "Sign-in cancelled."
        case .badCallback: return "Invalid response from Google."
        case .server(let m): return "Google: \(m)"
        }
    }
}

/// OAuth 2.0 + PKCE with ASWebAuthenticationSession ("iOS" client: no client secret).
@MainActor
final class AuthService: ObservableObject {
    @Published private(set) var isSignedIn: Bool

    private var tokens: Tokens?
    private var refreshTask: Task<Tokens, Error>?
    private var session: ASWebAuthenticationSession?
    private let anchor = AnchorProvider()
    private let http: URLSession
    private let storage: TokenStorage

    init(http: URLSession, storage: TokenStorage = KeychainStorage()) {
        self.http = http
        self.storage = storage
        if let d = storage.load(), let t = try? JSONDecoder().decode(Tokens.self, from: d) {
            tokens = t
        }
        isSignedIn = tokens != nil
    }

    // MARK: Sign in / out

    func signIn() async throws {
        let verifier = Self.random(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.random(16)

        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: Config.clientID),
            .init(name: "redirect_uri", value: Config.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Config.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]

        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: Config.redirectScheme) { url, err in
                if let url { cont.resume(returning: url) }
                else if let e = err as? ASWebAuthenticationSessionError, e.code == .canceledLogin { cont.resume(throwing: AuthError.cancelled) }
                else { cont.resume(throwing: err ?? AuthError.badCallback) }
            }
            s.presentationContextProvider = anchor
            session = s
            if !s.start() { cont.resume(throwing: AuthError.badCallback) }
        }
        session = nil

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let e = items.first(where: { $0.name == "error" })?.value { throw AuthError.server(e) }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.badCallback }

        let t = try await tokenRequest([
            "client_id": Config.clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": Config.redirectURI,
            "grant_type": "authorization_code",
        ], previousRefresh: nil)
        store(t)
    }

    func signOut() {
        tokens = nil
        refreshTask?.cancel(); refreshTask = nil
        storage.delete()
        Cache.clear()       // also on automatic sign-outs (invalid_grant)
        isSignedIn = false
    }

    // MARK: Tokens

    /// Returns a valid access token; refreshes transparently (a single request even with several concurrent callers).
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let t = tokens else { throw AuthError.signedOut }
        if !forceRefresh, t.expiry > Date().addingTimeInterval(60) { return t.access }
        if let task = refreshTask { return try await task.value.access }
        guard let refresh = t.refresh else { signOut(); throw AuthError.signedOut }

        let task = Task { [self] in
            try await tokenRequest([
                "client_id": Config.clientID,
                "refresh_token": refresh,
                "grant_type": "refresh_token",
            ], previousRefresh: refresh)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            store(new)
            return new.access
        } catch AuthError.server(let m) where m.contains("invalid_grant") {
            signOut()           // refresh token revoked/expired → back to sign-in
            throw AuthError.signedOut
        }
    }

    private func store(_ t: Tokens) {
        tokens = t
        if let d = try? JSONEncoder().encode(t) { storage.save(d) }
        isSignedIn = true
    }

    private func tokenRequest(_ form: [String: String], previousRefresh: String?) async throws -> Tokens {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)

        let (data, resp) = try await http.data(for: req)
        struct R: Decodable { let access_token: String?; let refresh_token: String?; let expires_in: Double?; let error: String?; let error_description: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let access = r.access_token else {
            throw AuthError.server([r.error, r.error_description].compactMap { $0 }.joined(separator: ": "))
        }
        return Tokens(access: access, refresh: r.refresh_token ?? previousRefresh,
                      expiry: Date().addingTimeInterval(r.expires_in ?? 3600))
    }

    private static func random(_ n: Int) -> String {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Menu bar app: hidden window used as the anchor for the web session.
private final class AnchorProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private lazy var window = NSWindow()
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? window
    }
}
