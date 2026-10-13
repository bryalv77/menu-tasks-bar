import Foundation

/// ÚNICO sitio a editar: pega aquí tu OAuth Client ID (tipo "iOS") de Google Cloud.
/// Formato: 1234567890-abcdef.apps.googleusercontent.com
enum Config {
    static let clientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"

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
