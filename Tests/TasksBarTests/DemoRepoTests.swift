import XCTest
@testable import TasksBar

final class DemoRepoTests: XCTestCase {
    private let repo = Demo.Repo()

    func testSeedData() async throws {
        let lists = try await repo.lists()
        XCTAssertEqual(lists.map(\.id), ["L1", "L2"])
        let t = try await repo.tasks(in: "L1")
        XCTAssertEqual(t.count, 5)
        XCTAssertEqual(t.filter(\.isCompleted).count, 2)
        XCTAssertEqual(t.first { $0.id == "a1" }?.parent, "a")
        let none = try await repo.tasks(in: "nope")
        XCTAssertTrue(none.isEmpty)
    }

    func testDemoIsOffByDefault() { XCTAssertFalse(Demo.isOn) }

    func testCreateOrdersLikeGoogle() async throws {
        let top = try await repo.create(in: "L1", title: "Top", notes: "n", due: nil, parent: nil, previous: nil)
        let rows = TaskRow.flatten(try await repo.tasks(in: "L1"), listID: "L1")
        XCTAssertEqual(rows.first?.id, top.id, "without previous it goes first")
        XCTAssertEqual(top.notes, "n")

        let sub = try await repo.create(in: "L1", title: "A3", notes: nil, due: nil, parent: "a", previous: "a2")
        let order = TaskRow.flatten(try await repo.tasks(in: "L1"), listID: "L1").filter { $0.task.parent == "a" }.map(\.id)
        XCTAssertEqual(order, ["a1", "a2", sub.id])
    }

    func testUpdateAndClearFields() async throws {
        var t = try await repo.update(in: "L1", taskID: "a", patch: ["title": "New", "status": "completed"])
        XCTAssertEqual(t.title, "New"); XCTAssertTrue(t.isCompleted); XCTAssertNotNil(t.completed)
        t = try await repo.update(in: "L1", taskID: "a", patch: ["notes": NSNull(), "status": "needsAction", "completed": NSNull()])
        XCTAssertNil(t.notes); XCTAssertFalse(t.isCompleted); XCTAssertNil(t.completed)
        let stored = try await repo.tasks(in: "L1")
        XCTAssertEqual(stored.first { $0.id == "a" }?.title, "New")
    }

    func testUpdateMissingThrows404() async {
        do { _ = try await repo.update(in: "L1", taskID: "zzz", patch: [:]); XCTFail() }
        catch APIError.http(let c, _) { XCTAssertEqual(c, 404) } catch { XCTFail("\(error)") }
    }

    func testDeleteTaskRemovesSubtasks() async throws {
        try await repo.delete(in: "L1", taskID: "a")
        let ids = try await repo.tasks(in: "L1").map(\.id)
        XCTAssertEqual(ids, ["b", "c"])
    }

    func testListCrud() async throws {
        let l = try await repo.createList(title: "Ideas")
        var all = try await repo.lists()
        XCTAssertEqual(all.last?.title, "Ideas")
        let r = try await repo.renameList(id: l.id, title: "Ideas 2")
        XCTAssertEqual(r.title, "Ideas 2")
        try await repo.deleteList(id: l.id)
        all = try await repo.lists()
        XCTAssertEqual(all.count, 2)
        do { _ = try await repo.renameList(id: "zzz", title: "x"); XCTFail() }
        catch APIError.http(let c, _) { XCTAssertEqual(c, 404) } catch { XCTFail("\(error)") }
    }

    func testDemoStorageIsAlwaysSignedIn() async throws {
        let st = Demo.Storage()
        let tokens = try JSONDecoder().decode(Tokens.self, from: st.load()!)
        XCTAssertTrue(tokens.expiry > Date().addingTimeInterval(3600))
        st.save(Data()); st.delete()
        XCTAssertNotNil(st.load(), "no persiste ni borra nada")
    }
}
