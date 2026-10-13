import XCTest
@testable import TasksBar

private final class MemoryStorage: TokenStorage {
    var data: Data?
    func load() -> Data? { data }
    func save(_ d: Data) { data = d }
    func delete() { data = nil }
    var tokens: Tokens? { data.flatMap { try? JSONDecoder().decode(Tokens.self, from: $0) } }
}

@MainActor
final class AuthTests: XCTestCase {
    private let mem = MemoryStorage()

    override func setUp() { FakeGoogle.reset(); mem.data = nil }

    private func seed(access: String = "old", refresh: String? = "R", expiresIn: TimeInterval = 3600) {
        mem.data = try! JSONEncoder().encode(Tokens(access: access, refresh: refresh, expiry: Date().addingTimeInterval(expiresIn)))
    }
    private func auth() -> AuthService { AuthService(http: FakeGoogle.session, storage: mem) }

    func testSignedInStateComesFromStorage() {
        XCTAssertFalse(auth().isSignedIn)
        seed()
        XCTAssertTrue(auth().isSignedIn)
    }

    func testSignedOutThrows() async {
        do { _ = try await auth().accessToken(); XCTFail() } catch AuthError.signedOut {} catch { XCTFail("\(error)") }
    }

    func testValidTokenIsReturnedWithoutNetwork() async throws {
        seed()
        let t = try await auth().accessToken()
        XCTAssertEqual(t, "old")
        XCTAssertTrue(FakeGoogle.tokenForms.isEmpty)
    }

    func testExpiredTokenRefreshesAndPersistsKeepingRefreshToken() async throws {
        seed(expiresIn: -10)
        let a = auth()
        let t = try await a.accessToken()
        XCTAssertEqual(t, "fresh")
        XCTAssertTrue(FakeGoogle.tokenForms[0].contains("grant_type=refresh_token"))
        XCTAssertTrue(FakeGoogle.tokenForms[0].contains("refresh_token=R"))
        XCTAssertEqual(mem.tokens?.access, "fresh")
        XCTAssertEqual(mem.tokens?.refresh, "R", "Google no reenvía el refresh token")
    }

    func testTokenNearExpiryRefreshes() async throws {
        seed(expiresIn: 30)
        let t = try await auth().accessToken()
        XCTAssertEqual(t, "fresh")
    }

    func testForceRefreshIgnoresValidToken() async throws {
        seed()
        let t = try await auth().accessToken(forceRefresh: true)
        XCTAssertEqual(t, "fresh")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        seed(expiresIn: -10)
        FakeGoogle.delay = 0.1
        let a = auth()
        let results = try await withThrowingTaskGroup(of: String.self) { g in
            for _ in 0..<5 { g.addTask { try await a.accessToken() } }
            return try await g.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(results, Array(repeating: "fresh", count: 5))
        XCTAssertEqual(FakeGoogle.tokenForms.count, 1)
    }

    func testInvalidGrantSignsOut() async {
        seed(expiresIn: -10)
        FakeGoogle.tokenStatus = 400
        FakeGoogle.tokenBody = ["error": "invalid_grant"]
        let a = auth()
        do { _ = try await a.accessToken(); XCTFail() } catch AuthError.signedOut {} catch { XCTFail("\(error)") }
        XCTAssertFalse(a.isSignedIn)
        XCTAssertNil(mem.data)
    }

    func testOtherServerErrorKeepsSession() async {
        seed(expiresIn: -10)
        FakeGoogle.tokenStatus = 500
        FakeGoogle.tokenBody = ["error": "backend_error", "error_description": "boom"]
        let a = auth()
        do { _ = try await a.accessToken(); XCTFail() }
        catch AuthError.server(let m) { XCTAssertEqual(m, "backend_error: boom") }
        catch { XCTFail("\(error)") }
        XCTAssertTrue(a.isSignedIn)
    }

    func testExpiredWithoutRefreshTokenSignsOut() async {
        seed(refresh: nil, expiresIn: -10)
        let a = auth()
        do { _ = try await a.accessToken(); XCTFail() } catch AuthError.signedOut {} catch { XCTFail("\(error)") }
        XCTAssertFalse(a.isSignedIn)
    }

    func testSignOutClearsStorage() {
        seed()
        let a = auth()
        a.signOut()
        XCTAssertFalse(a.isSignedIn)
        XCTAssertNil(mem.data)
    }

    /// Integración: la API recibe 401, refresca el token y reintenta una vez.
    func testAPIRecoversFrom401ThroughRealAuth() async throws {
        seed()
        FakeGoogle.seed(list: "L", "L")
        FakeGoogle.failures = [401]
        let api = TasksAPI(http: FakeGoogle.session, auth: auth())
        let lists = try await api.lists()
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(FakeGoogle.tokenForms.count, 1)
        XCTAssertEqual(mem.tokens?.access, "fresh")
    }

    func testConfigAndErrorMessages() {
        XCTAssertTrue(Config.redirectURI.hasPrefix("com.googleusercontent.apps."))
        XCTAssertTrue(Config.redirectURI.hasSuffix(":/oauth2redirect"))
        XCTAssertFalse(Config.redirectScheme.contains(".apps.googleusercontent.com"))
        XCTAssertEqual(AuthError.signedOut.errorDescription, "Sesión no iniciada.")
        XCTAssertEqual(AuthError.server("x").errorDescription, "Google: x")
        XCTAssertEqual(APIError.offline.errorDescription, "Sin conexión.")
    }
}
