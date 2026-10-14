import Foundation
@testable import TasksBar

/// In-memory fake Google Tasks server, plugged into a URLSession via URLProtocol.
final class FakeGoogle: URLProtocol {
    nonisolated(unsafe) static var lists: [[String: Any]] = []
    nonisolated(unsafe) static var tasks: [String: [[String: Any]]] = [:]
    nonisolated(unsafe) static var requests: [(method: String, path: String, query: [String: String], body: [String: Any])] = []
    nonisolated(unsafe) static var failures: [Int] = []       // HTTP codes for the next requests
    nonisolated(unsafe) static var offline = false
    nonisolated(unsafe) static var pageSize = 100
    nonisolated(unsafe) static var counter = 0
    nonisolated(unsafe) static var delay: TimeInterval = 0       // response latency
    nonisolated(unsafe) static var tokenStatus = 200
    nonisolated(unsafe) static var tokenBody: [String: Any] = ["access_token": "fresh", "expires_in": 3600]
    nonisolated(unsafe) static var tokenForms: [String] = []     // bodies sent to /token
    private static let lock = NSLock()

    static func reset() {
        lock.withLock { lists = []; tasks = [:]; requests = []; failures = []; offline = false; pageSize = 100; counter = 0; delay = 0; tokenStatus = 200; tokenBody = ["access_token": "fresh", "expires_in": 3600]; tokenForms = [] }
    }

    static var session: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeGoogle.self]
        return URLSession(configuration: c)
    }

    static func seed(list id: String, _ title: String, tasks ts: [[String: Any]] = []) {
        lock.withLock { lists.append(["id": id, "title": title]); tasks[id] = ts }
    }

    static func task(_ id: String, _ title: String, parent: String? = nil, pos: String? = nil, status: String = "needsAction") -> [String: Any] {
        var t: [String: Any] = ["id": id, "title": title, "status": status, "position": pos ?? id]
        if let parent { t["parent"] = parent }
        return t
    }

    static func titles(_ list: String) -> [String] { lock.withLock { (tasks[list] ?? []).map { $0["title"] as! String } } }
    static func count(_ method: String, _ prefix: String = "") -> Int {
        lock.withLock { requests.filter { $0.method == method && $0.path.hasPrefix(prefix) }.count }
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, data) = Self.lock.withLock { Self.handle(request) }
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let respond = { [self] in
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/2", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        let d = Self.delay
        if d > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + d, execute: respond) } else { respond() }
    }

    private static func handle(_ req: URLRequest) -> (Int, Data) {
        if offline { return (-1, Data()) }
        let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let path = comps.path.replacingOccurrences(of: "/tasks/v1", with: "")
        let query = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        var raw = Data()
        if let s = req.httpBodyStream {
            s.open(); defer { s.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            while s.hasBytesAvailable { let n = s.read(&buf, maxLength: buf.count); if n <= 0 { break }; raw.append(buf, count: n) }
        }
        if comps.host == "oauth2.googleapis.com" {
            tokenForms.append(String(decoding: raw, as: UTF8.self))
            return (tokenStatus, (try? JSONSerialization.data(withJSONObject: tokenBody)) ?? Data())
        }
        let body = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
        let method = req.httpMethod ?? "GET"
        requests.append((method, path, query, body))
        if !failures.isEmpty { return (failures.removeFirst(), Data("{\"error\":\"boom\"}".utf8)) }

        let p = path.split(separator: "/").map(String.init)
        func json(_ o: Any) -> (Int, Data) { (200, (try? JSONSerialization.data(withJSONObject: o)) ?? Data()) }
        func page(_ items: [[String: Any]]) -> (Int, Data) {
            let start = Int(query["pageToken"] ?? "0")!
            let slice = Array(items.dropFirst(start).prefix(pageSize))
            var o: [String: Any] = ["items": slice]
            if start + pageSize < items.count { o["nextPageToken"] = String(start + pageSize) }
            return json(o)
        }
        func apply(_ patch: [String: Any], to o: inout [String: Any]) {
            for (k, v) in patch { if v is NSNull { o[k] = nil } else { o[k] = v } }
        }

        let id = p.count > (p.first == "users" ? 3 : 3) ? p[3] : nil
        if p.starts(with: ["users", "@me", "lists"]) {
            switch (method, id) {
            case ("GET", nil): return page(lists)
        case ("POST", nil):
            counter += 1
            let l: [String: Any] = ["id": "N\(counter)", "title": body["title"] ?? ""]
            lists.append(l); tasks[l["id"] as! String] = []
            return json(l)
        case ("PATCH", let id?):
            guard let i = lists.firstIndex(where: { $0["id"] as? String == id }) else { return (404, Data()) }
            apply(body, to: &lists[i]); return json(lists[i])
        case ("DELETE", let id?):
            guard lists.contains(where: { $0["id"] as? String == id }) else { return (404, Data()) }
            lists.removeAll { $0["id"] as? String == id }; tasks[id] = nil
            return (204, Data())
            default: return (404, Data())
            }
        }
        guard p.count >= 3, p[0] == "lists", p[2] == "tasks" else { return (404, Data()) }
        let lid = p[1]
        switch (method, id) {
        case ("GET", nil):
            guard let ts = tasks[lid] else { return (404, Data()) }
            return page(ts)
        case ("POST", nil):
            guard tasks[lid] != nil else { return (404, Data()) }
            counter += 1
            var t = body
            t["id"] = "T\(counter)"
            t["status"] = "needsAction"
            // Like Google: without `previous` it goes first among its siblings; with `previous`, right after it.
            let sibs = tasks[lid]!.filter { $0["parent"] as? String == query["parent"] }
            if let prev = query["previous"], let pp = tasks[lid]!.first(where: { $0["id"] as? String == prev })?["position"] as? String {
                t["position"] = pp + "~"
            } else {
                t["position"] = "!" + ((sibs.compactMap { $0["position"] as? String }.min()) ?? "")
            }
            if let parent = query["parent"] { t["parent"] = parent }
            tasks[lid]!.append(t)
            return json(t)
        case ("PATCH", let id?):
            guard let i = tasks[lid]?.firstIndex(where: { $0["id"] as? String == id }) else { return (404, Data()) }
            apply(body, to: &tasks[lid]![i])
            if body["status"] as? String == "completed" { tasks[lid]![i]["completed"] = ISO8601DateFormatter.withFraction.string(from: Date()) }
            return json(tasks[lid]![i])
        case ("DELETE", let id?):
            guard tasks[lid]?.contains(where: { $0["id"] as? String == id }) == true else { return (404, Data()) }
            tasks[lid]!.removeAll { $0["id"] as? String == id || $0["parent"] as? String == id }
            return (204, Data())
        default: return (404, Data())
        }
    }
}
