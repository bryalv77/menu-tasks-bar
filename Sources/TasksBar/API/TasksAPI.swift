import Foundation

enum APIError: LocalizedError {
    case http(Int, String), offline
    var errorDescription: String? {
        switch self {
        case .http(let c, let m): return m.isEmpty ? "Error \(c)" : "Error \(c): \(m)"
        case .offline: return "No connection."
        }
    }
}

/// Remote repository. The Store depends on this protocol → testable with fake data.
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

/// Lightweight Google Tasks REST client. A single URLSession (HTTP/2 + keep-alive).
final class TasksAPI: TasksRepository {
    private let http: URLSession
    private let token: (_ forceRefresh: Bool) async throws -> String

    init(http: URLSession, auth: AuthService) {
        self.http = http
        token = { try await auth.accessToken(forceRefresh: $0) }
    }

    /// For tests: injectable token.
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

    /// Partial PATCH; use NSNull() as the value to clear a field.
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

    /// Google only uses the date: midnight UTC of the chosen local calendar day.
    static func dueString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", c.year!, c.month!, c.day!)
    }

    /// Only Google's `error.message`; never the raw body (may be HTML or technical text).
    static func errorMessage(from data: Data) -> String {
        struct E: Decodable { struct B: Decodable { let message: String? }; let error: B? }
        return (try? JSONDecoder().decode(E.self, from: data))?.error?.message.map { String($0.prefix(200)) } ?? ""
    }

    // MARK: Core

    /// An ID must never be able to add segments or parameters to the path.
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
                throw APIError.http(status, Self.errorMessage(from: data))
            }
            if T.self == EmptyResponse.self { return EmptyResponse() as! T }
            return try JSONDecoder().decode(T.self, from: data)
        }
    }
}

struct EmptyResponse: Decodable {}
