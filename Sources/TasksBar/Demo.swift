#if DEBUG
import Foundation

/// Modo demo (solo builds debug): `TASKSBAR_FAKE=1 swift run` arranca la app con datos en memoria, sin login ni red.
enum Demo {
    static let isOn = ProcessInfo.processInfo.environment["TASKSBAR_FAKE"] == "1"

    /// Sesión falsa siempre válida; no toca el Keychain real.
    final class Storage: TokenStorage {
        func load() -> Data? { try? JSONEncoder().encode(Tokens(access: "demo", refresh: "demo", expiry: .distantFuture)) }
        func save(_ data: Data) {}
        func delete() {}
    }

    actor Repo: TasksRepository {
        private var lists: [TaskList] = [.init(id: "L1", title: "Trabajo"), .init(id: "L2", title: "Casa")]
        private var tasks: [String: [GTask]] = [:]
        private var n = 0

        init() {
            func t(_ id: String, _ title: String, parent: String? = nil, pos: String, done: Bool = false, due: Int? = nil, notes: String? = nil) -> GTask {
                var j: [String: Any] = ["id": id, "title": title, "position": pos, "status": done ? "completed" : "needsAction"]
                if let parent { j["parent"] = parent }
                if let notes { j["notes"] = notes }
                if done { j["completed"] = ISO8601DateFormatter.withFraction.string(from: Date()) }
                if let due { j["due"] = TasksAPI.dueString(Calendar.current.date(byAdding: .day, value: due, to: Date())!) }
                return try! JSONDecoder().decode(GTask.self, from: JSONSerialization.data(withJSONObject: j))
            }
            tasks["L1"] = [
                t("a", "Preparar demo del viernes", pos: "01", due: 1, notes: "Revisar slides"),
                t("a1", "Ensayar presentación", parent: "a", pos: "01"),
                t("a2", "Enviar invitación", parent: "a", pos: "02", done: true),
                t("b", "Responder correos", pos: "02", due: -1),
                t("c", "Revisar PR", pos: "03", done: true),
            ]
            tasks["L2"] = [t("h", "Comprar café", pos: "01", due: 0), t("h2", "Llamar al plomero", pos: "02")]
        }

        private func next() -> String { n += 1; return "N\(n)" }

        func lists() async throws -> [TaskList] { lists }
        func tasks(in listID: String) async throws -> [GTask] { tasks[listID] ?? [] }

        func create(in listID: String, title: String, notes: String?, due: Date?, parent: String?, previous: String?) async throws -> GTask {
            var j: [String: Any] = ["id": next(), "title": title]
            if let notes { j["notes"] = notes }
            if let due { j["due"] = TasksAPI.dueString(due) }
            if let parent { j["parent"] = parent }
            let sibs = (tasks[listID] ?? []).filter { $0.parent == parent }
            let prev = previous.flatMap { p in sibs.first { $0.id == p }?.position }
            j["position"] = prev.map { $0 + "~" } ?? "!" + (sibs.compactMap(\.position).min() ?? "")
            let t = try JSONDecoder().decode(GTask.self, from: JSONSerialization.data(withJSONObject: j))
            tasks[listID, default: []].append(t)
            return t
        }

        func update(in listID: String, taskID: String, patch: [String: Any]) async throws -> GTask {
            guard let i = tasks[listID]?.firstIndex(where: { $0.id == taskID }) else { throw APIError.http(404, "") }
            var j = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(tasks[listID]![i])) as? [String: Any]) ?? [:]
            for (k, v) in patch { j[k] = v is NSNull ? nil : v }
            if patch["status"] as? String == "completed" { j["completed"] = ISO8601DateFormatter.withFraction.string(from: Date()) }
            let t = try JSONDecoder().decode(GTask.self, from: JSONSerialization.data(withJSONObject: j))
            tasks[listID]![i] = t
            return t
        }

        func delete(in listID: String, taskID: String) async throws {
            tasks[listID]?.removeAll { $0.id == taskID || $0.parent == taskID }
        }

        func createList(title: String) async throws -> TaskList {
            let l = TaskList(id: next(), title: title); lists.append(l); tasks[l.id] = []; return l
        }

        func renameList(id: String, title: String) async throws -> TaskList {
            guard let i = lists.firstIndex(where: { $0.id == id }) else { throw APIError.http(404, "") }
            lists[i].title = title; return lists[i]
        }

        func deleteList(id: String) async throws { lists.removeAll { $0.id == id }; tasks[id] = nil }
    }
}
#endif
