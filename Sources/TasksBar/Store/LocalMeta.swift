import Foundation

/// Datos que la API de Google Tasks no soporta (favoritas y hora del día). Solo existen en este Mac.
struct LocalMeta: Codable, Equatable {
    var favorites: [String: String] = [:]   // taskID → listID
    var minutes: [String: Int] = [:]        // taskID → minutos desde medianoche

    private static let key: String = {
        #if DEBUG
        if Demo.isOn { return "localMeta-demo" }   // no mezclar favoritas demo con las reales
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
