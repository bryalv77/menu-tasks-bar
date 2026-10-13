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
}

/// Cliente ligero de Google Tasks REST. Una única URLSession (HTTP/2 + keep-alive).
final class TasksAPI: TasksRepository {
    private let http: URLSession
    private let auth: AuthService

    init(http: URLSession, auth: AuthService) { self.http = http; self.auth = auth }

    func lists() async throws -> [TaskList] {
        try await paged("/users/@me/lists", query: [.init(name: "maxResults", value: "100")])
    }

    func tasks(in listID: String) async throws -> [GTask] {
        try await paged("/lists/\(listID)/tasks", query: [
            .init(name: "maxResults", value: "100"),
            .init(name: "showCompleted", value: "true"),
            .init(name: "showHidden", value: "true"),
        ])
    }

    // MARK: Núcleo

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
            req.setValue("Bearer \(try await auth.accessToken(forceRefresh: retriedAuth))", forHTTPHeaderField: "Authorization")

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
