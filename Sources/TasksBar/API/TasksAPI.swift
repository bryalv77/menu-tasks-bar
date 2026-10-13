import Foundation

enum APIError: LocalizedError {
    case http(Int, String), offline
    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return "Error \(c): \(m)"
        case .offline: return "Sin conexión."
        }
    }
}

/// Repositorio remoto. El Store depende de este protocolo → testeable con datos falsos.
protocol TasksRepository {
    func lists() async throws -> [TaskList]
    func tasks(in listID: String) async throws -> [GTask]
    func create(in listID: String, title: String, notes: String?, due: Date?, parent: String?, previous: String?) async throws -> GTask
    func update(in listID: String, taskID: String, patch: [String: Any]) async throws -> GTask
    func delete(in listID: String, taskID: String) async throws
    func createList(title: String) async throws -> TaskList
    func renameList(id: String, title: String) async throws -> TaskList
    func deleteList(id: String) async throws
}

/// Cliente ligero de Google Tasks REST. Una única URLSession (HTTP/2 + keep-alive).
final class TasksAPI: TasksRepository {
    private let http: URLSession
    private let token: (_ forceRefresh: Bool) async throws -> String

    init(http: URLSession, auth: AuthService) {
        self.http = http
        token = { try await auth.accessToken(forceRefresh: $0) }
    }

    /// Para tests: token inyectable.
    init(http: URLSession, token: @escaping (_ forceRefresh: Bool) async throws -> String) {
        self.http = http; self.token = token
    }

    func lists() async throws -> [TaskList] {
        try await paged("/users/@me/lists", query: [.init(name: "maxResults", value: "100")])
    }

    func tasks(in listID: String) async throws -> [GTask] {
        try await paged("/lists/\(seg(listID))/tasks", query: [
            .init(name: "maxResults", value: "100"),
            .init(name: "showCompleted", value: "true"),
            .init(name: "showHidden", value: "true"),
        ])
    }

    func create(in listID: String, title: String, notes: String?, due: Date?, parent: String?, previous: String?) async throws -> GTask {
        var b: [String: Any] = ["title": title]
        if let notes, !notes.isEmpty { b["notes"] = notes }
        if let due { b["due"] = Self.dueString(due) }
        var q: [URLQueryItem] = []
        if let parent { q.append(.init(name: "parent", value: parent)) }
        if let previous { q.append(.init(name: "previous", value: previous)) }
        return try await send("POST", "/lists/\(seg(listID))/tasks", query: q, body: JSONSerialization.data(withJSONObject: b))
    }

    /// PATCH parcial; usar NSNull() como valor para borrar un campo.
    func update(in listID: String, taskID: String, patch: [String: Any]) async throws -> GTask {
        try await send("PATCH", "/lists/\(seg(listID))/tasks/\(seg(taskID))", body: JSONSerialization.data(withJSONObject: patch))
    }

    func delete(in listID: String, taskID: String) async throws {
        let _: EmptyResponse = try await send("DELETE", "/lists/\(seg(listID))/tasks/\(seg(taskID))")
    }

    func createList(title: String) async throws -> TaskList {
        try await send("POST", "/users/@me/lists", body: JSONSerialization.data(withJSONObject: ["title": title]))
    }

    func renameList(id: String, title: String) async throws -> TaskList {
        try await send("PATCH", "/users/@me/lists/\(seg(id))", body: JSONSerialization.data(withJSONObject: ["title": title]))
    }

    func deleteList(id: String) async throws {
        let _: EmptyResponse = try await send("DELETE", "/users/@me/lists/\(seg(id))")
    }

    /// Google solo usa la fecha: medianoche UTC del día calendario local elegido.
    static func dueString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", c.year!, c.month!, c.day!)
    }

    // MARK: Núcleo

    /// Un ID nunca debe poder añadir segmentos ni parámetros a la ruta.
    private func seg(_ s: String) -> String {
        var a = CharacterSet.urlPathAllowed; a.remove("/")
        return s.addingPercentEncoding(withAllowedCharacters: a) ?? ""
    }

    private func paged<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> [T] {
        var all: [T] = []
        var token: String?
        repeat {
            var q = query
            if let token { q.append(.init(name: "pageToken", value: token)) }
            let page: Page<T> = try await send("GET", path, query: q)
            all += page.items ?? []
            token = page.nextPageToken
        } while token != nil
        return all
    }

    func send<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        var c = URLComponents(string: Config.apiBase + path)!
        if !query.isEmpty { c.queryItems = query }
        var retriedAuth = false
        while true {
            var req = URLRequest(url: c.url!)
            req.httpMethod = method
            req.httpBody = body
            if body != nil { req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            req.setValue("Bearer \(try await token(retriedAuth))", forHTTPHeaderField: "Authorization")

            let data: Data, resp: URLResponse
            do { (data, resp) = try await http.data(for: req) }
            catch let e as URLError where [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(e.code) {
                throw APIError.offline
            }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401, !retriedAuth { retriedAuth = true; continue }
            guard (200..<300).contains(status) else {
                throw APIError.http(status, String(data: data, encoding: .utf8)?.prefix(200).description ?? "")
            }
            if T.self == EmptyResponse.self { return EmptyResponse() as! T }
            return try JSONDecoder().decode(T.self, from: data)
        }
    }
}

struct EmptyResponse: Decodable {}
