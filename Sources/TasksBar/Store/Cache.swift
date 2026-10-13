import Foundation

struct Snapshot: Codable {
    var lists: [TaskList] = []
    var tasks: [String: [GTask]] = [:]
    var selectedListID: String?
}

/// Caché JSON en Application Support. Carga síncrona (pequeña) para pintar al instante; escritura fuera del hilo principal.
enum Cache {
    private static var isDemo: Bool {
        #if DEBUG
        return Demo.isOn
        #else
        return false
        #endif
    }
    private static let url: URL = {
        // Bajo XCTest o modo demo usamos un directorio temporal para no tocar la caché real del usuario.
        let base = NSClassFromString("XCTestCase") != nil || Self.isDemo ? FileManager.default.temporaryDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TasksBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("cache.json")
    }()
    private static let queue = DispatchQueue(label: "tasksbar.cache", qos: .utility)

    static func load() -> Snapshot {
        // queue.sync: ordena la lectura tras escrituras/borrados pendientes.
        guard let d = queue.sync(execute: { try? Data(contentsOf: url) }), let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return Snapshot() }
        return s
    }

    static func save(_ s: Snapshot) {
        queue.async {
            guard let d = try? JSONEncoder().encode(s), (try? d.write(to: url, options: .atomic)) != nil else { return }
            // Títulos y notas de tareas: solo legibles por el usuario.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func clear() { queue.async { try? FileManager.default.removeItem(at: url) } }
}
