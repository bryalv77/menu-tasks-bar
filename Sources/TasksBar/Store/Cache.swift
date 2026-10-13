import Foundation

struct Snapshot: Codable {
    var lists: [TaskList] = []
    var tasks: [String: [GTask]] = [:]
    var selectedListID: String?
}

/// Caché JSON en Application Support. Carga síncrona (pequeña) para pintar al instante; escritura fuera del hilo principal.
enum Cache {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TasksBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }()
    private static let queue = DispatchQueue(label: "tasksbar.cache", qos: .utility)

    static func load() -> Snapshot {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return Snapshot() }
        return s
    }

    static func save(_ s: Snapshot) {
        queue.async { if let d = try? JSONEncoder().encode(s) { try? d.write(to: url, options: .atomic) } }
    }

    static func clear() { queue.async { try? FileManager.default.removeItem(at: url) } }
}
