import XCTest
@testable import TasksBar

final class ModelsTests: XCTestCase {
    private func decode(_ json: String) throws -> GTask { try JSONDecoder().decode(GTask.self, from: Data(json.utf8)) }

    func testDecodeAppliesDefaults() throws {
        let t = try decode(#"{"id":"a"}"#)
        XCTAssertEqual(t.title, "")
        XCTAssertEqual(t.status, "needsAction")
        XCTAssertFalse(t.isCompleted)
        XCTAssertNil(t.parent)
    }

    func testCompletedDateParsesWithAndWithoutFraction() throws {
        XCTAssertNotNil(try decode(#"{"id":"a","status":"completed","completed":"2026-01-01T10:00:00.000Z"}"#).completedDate)
        XCTAssertNotNil(try decode(#"{"id":"a","status":"completed","completed":"2026-01-01T10:00:00Z"}"#).completedDate)
        XCTAssertNil(try decode(#"{"id":"a"}"#).completedDate)
    }

    func testFlattenSortsByPositionAndNests() throws {
        let ts = try [
            decode(#"{"id":"b","title":"B","position":"02"}"#),
            decode(#"{"id":"a","title":"A","position":"01"}"#),
            decode(#"{"id":"a2","title":"A2","position":"02","parent":"a"}"#),
            decode(#"{"id":"a1","title":"A1","position":"01","parent":"a"}"#),
            decode(#"{"id":"a1x","title":"A1x","position":"01","parent":"a1"}"#),
        ]
        let rows = TaskRow.flatten(ts, listID: "L")
        XCTAssertEqual(rows.map(\.id), ["a", "a1", "a1x", "a2", "b"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 1, 0])
        XCTAssertTrue(rows.allSatisfy { $0.listID == "L" })
    }

    func testFlattenPromotesOrphanedSubtask() throws {
        let rows = TaskRow.flatten([try decode(#"{"id":"x","parent":"missing"}"#)], listID: "L")
        XCTAssertEqual(rows.map(\.depth), [0])
    }

    func testDueStringUsesLocalCalendarDay() {
        let d = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 59))!
        XCTAssertEqual(TasksAPI.dueString(d), "2026-03-07T00:00:00.000Z")
    }
}

final class APITests: XCTestCase {
    private var tokenCalls: [Bool] = []
    private lazy var api = TasksAPI(http: FakeGoogle.session) { [unowned self] force in tokenCalls.append(force); return force ? "new" : "old" }

    override func setUp() { FakeGoogle.reset(); tokenCalls = [] }

    func testListsPaginatesAndSendsBearer() async throws {
        FakeGoogle.pageSize = 2
        for i in 1...5 { FakeGoogle.seed(list: "L\(i)", "T\(i)") }
        let l = try await api.lists()
        XCTAssertEqual(l.map(\.id), ["L1", "L2", "L3", "L4", "L5"])
        XCTAssertEqual(FakeGoogle.count("GET", "/users/@me/lists"), 3)
    }

    func testTasksPaginatesAndRequestsCompletedAndHidden() async throws {
        FakeGoogle.pageSize = 1
        FakeGoogle.seed(list: "L", "L", tasks: [FakeGoogle.task("a", "A"), FakeGoogle.task("b", "B")])
        let t = try await api.tasks(in: "L")
        XCTAssertEqual(t.map(\.id), ["a", "b"])
        let q = FakeGoogle.requests[0].query
        XCTAssertEqual(q["showCompleted"], "true"); XCTAssertEqual(q["showHidden"], "true")
    }

    func testCreateSendsParentPreviousAndOmitsEmptyNotes() async throws {
        FakeGoogle.seed(list: "L", "L")
        _ = try await api.create(in: "L", title: "x", notes: "", due: nil, parent: "P", previous: "Q")
        let r = FakeGoogle.requests[0]
        XCTAssertEqual(r.query["parent"], "P"); XCTAssertEqual(r.query["previous"], "Q")
        XCTAssertEqual(r.body["title"] as? String, "x")
        XCTAssertNil(r.body["notes"]); XCTAssertNil(r.body["due"])
    }

    func testPatchNSNullClearsField() async throws {
        FakeGoogle.seed(list: "L", "L", tasks: [FakeGoogle.task("a", "A")])
        var t = try await api.update(in: "L", taskID: "a", patch: ["notes": "hi"])
        XCTAssertEqual(t.notes, "hi")
        t = try await api.update(in: "L", taskID: "a", patch: ["notes": NSNull()])
        XCTAssertNil(t.notes)
    }

    func test401RefreshesTokenOnceAndRetries() async throws {
        FakeGoogle.failures = [401]
        _ = try await api.lists()
        XCTAssertEqual(tokenCalls, [false, true])
    }

    func testSecond401SurfacesAsHTTPError() async {
        FakeGoogle.failures = [401, 401]
        do { _ = try await api.lists(); XCTFail() }
        catch APIError.http(let c, _) { XCTAssertEqual(c, 401) }
        catch { XCTFail("\(error)") }
    }

    func testHTTPErrorCarriesStatus() async {
        FakeGoogle.failures = [500]
        do { _ = try await api.lists(); XCTFail() }
        catch let e as APIError { XCTAssertTrue(e.localizedDescription.hasPrefix("Error 500")) }
        catch { XCTFail("\(error)") }
    }

    func testOfflineMapsToOfflineError() async {
        FakeGoogle.offline = true
        do { _ = try await api.lists(); XCTFail() }
        catch APIError.offline {}
        catch { XCTFail("\(error)") }
    }

    func testDeleteAndListCrud() async throws {
        let l = try await api.createList(title: "Home")
        let r = try await api.renameList(id: l.id, title: "Casa")
        XCTAssertEqual(r.title, "Casa")
        try await api.deleteList(id: l.id)
        let rest = try await api.lists()
        XCTAssertTrue(rest.isEmpty)
    }
}

final class ErrorMessageTests: XCTestCase {
    func testOnlyGoogleMessageIsShown() {
        let json = #"{"error":{"code":403,"message":"Tasks API has not been used"}}"#
        XCTAssertEqual(TasksAPI.errorMessage(from: Data(json.utf8)), "Tasks API has not been used")
        XCTAssertEqual(TasksAPI.errorMessage(from: Data("<html>502 Bad Gateway</html>".utf8)), "")
        XCTAssertEqual(APIError.http(502, "").errorDescription, "Error 502")
    }
}
