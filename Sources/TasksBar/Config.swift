import Foundation

/// The OAuth Client ID ("iOS" type) is not kept in the repo: `scripts/build.sh` injects it into the Info.plist
/// from `client.plist` (ignored by git). With `swift run`/tests: the TASKSBAR_CLIENT_ID environment variable.
enum Config {
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "CLIENT_ID") as? String
        ?? ProcessInfo.processInfo.environment["TASKSBAR_CLIENT_ID"]
        ?? "YOUR_CLIENT_ID.apps.googleusercontent.com"

    static let scope = "https://www.googleapis.com/auth/tasks"
    static let apiBase = "https://tasks.googleapis.com/tasks/v1"

    /// Redirect scheme = reversed client ID (required by Google for iOS clients).
    static var redirectScheme: String {
        let prefix = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(prefix)"
    }
    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }
    static var isConfigured: Bool { !clientID.hasPrefix("YOUR_CLIENT_ID") }
}
