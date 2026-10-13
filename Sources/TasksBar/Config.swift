import Foundation

/// El OAuth Client ID (tipo "iOS") no vive en el repo: `scripts/build.sh` lo inyecta en el Info.plist
/// desde `client.plist` (ignorado por git). Con `swift run`/tests: variable de entorno TASKSBAR_CLIENT_ID.
enum Config {
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "CLIENT_ID") as? String
        ?? ProcessInfo.processInfo.environment["TASKSBAR_CLIENT_ID"]
        ?? "YOUR_CLIENT_ID.apps.googleusercontent.com"

    static let scope = "https://www.googleapis.com/auth/tasks"
    static let apiBase = "https://tasks.googleapis.com/tasks/v1"

    /// Esquema de redirect = reverse client ID (lo exige Google para clientes iOS).
    static var redirectScheme: String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
    static var isConfigured: Bool { !clientID.hasPrefix("YOUR_CLIENT_ID") }
}
