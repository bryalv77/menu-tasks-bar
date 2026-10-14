import Foundation

struct TaskList: Codable, Identifiable, Hashable {
    let id: String
    var title: String
}

struct GTask: Codable, Identifiable, Hashable {
    let id: String
    var title: String
    var notes: String?
    var status: String          // "needsAction" | "completed"
    var due: String?            // RFC 3339 (Google only uses the date part)
    var parent: String?
    var position: String?
    var updated: String?
    var completed: String?      // RFC 3339, only if status == completed
    var deleted: Bool?
    var hidden: Bool?

    var isCompleted: Bool { status == "completed" }

    var completedDate: Date? {
        guard let completed else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: completed) ?? ISO8601DateFormatter().date(from: completed)
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "needsAction"
        due = try c.decodeIfPresent(String.self, forKey: .due)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        updated = try c.decodeIfPresent(String.self, forKey: .updated)
        completed = try c.decodeIfPresent(String.self, forKey: .completed)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden)
    }
}

struct Page<T: Decodable>: Decodable {
    let items: [T]?
    let nextPageToken: String?
}

/// Already-flattened row ready to draw (subtasks have depth > 0).
struct TaskRow: Identifiable, Hashable {
    let task: GTask
    let depth: Int
    let listID: String
    var id: String { task.id }

    /// Sorts by `position` (zero-padded numeric strings → lexical order) and nests by `parent`.
    static func flatten(_ tasks: [GTask], listID: String) -> [TaskRow] {
        let ids = Set(tasks.map(\.id))
        let byParent = Dictionary(grouping: tasks) { t -> String in
            if let p = t.parent, ids.contains(p) { return p }
            return ""
        }
        var out: [TaskRow] = []
        func walk(_ parent: String, _ depth: Int) {
            for t in (byParent[parent] ?? []).sorted(by: { ($0.position ?? "") < ($1.position ?? "") }) {
                out.append(TaskRow(task: t, depth: depth, listID: listID))
                walk(t.id, depth + 1)
            }
        }
        walk("", 0)
        return out
    }
}
