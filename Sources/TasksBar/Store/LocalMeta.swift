import Foundation

/// Data the Google Tasks API doesn't support (favorites and time of day). They only exist on this Mac.
struct LocalMeta: Codable, Equatable {
    var favorites: [String: String] = [:]   // taskID → listID
    var minutes: [String: Int] = [:]        // taskID → minutes since midnight

    private static let key: String = {
        #if DEBUG
        if Demo.isOn { return "localMeta-demo" }   // don't mix demo favorites with the real ones
        #endif
        return "localMeta"
    }()

    static func load() -> LocalMeta {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode(LocalMeta.self, from: d) else { return LocalMeta() }
        return m
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key) }
    }
}
