import XCTest
@testable import TasksBar

/// Races: the fake server responds with latency to leave operations in flight.
@MainActor
final class ConcurrencyTests: XCTestCase {
    private var store: TasksStore!

    override func setUp() {
        FakeGoogle.reset()
        for k in ["showSubtasks", "showCompleted", "completedDays", "maxCompleted", "showBadge", "defaultListID"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        LocalMeta().save(); Cache.clear()
        FakeGoogle.seed(list: "L1", "Work", tasks: [FakeGoogle.task("a", "A", pos: "01"), FakeGoogle.task("b", "B", pos: "02")])
    }

    private func boot() async {
        store = TasksStore(repo: TasksAPI(http: FakeGoogle.session) { _ in "t" }, settings: AppSettings())
        await store.sync()
    }

    private func eventually(_ c: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 { if c() { return }; try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("timeout", file: file, line: line)
    }

    func testSyncIsDeferredWhileWriteInFlight() async {
        await boot()
        let before = FakeGoogle.count("GET", "/users/@me/lists")
        FakeGoogle.delay = 0.2
        let add = Task { await store.add(title: "Slow") }
        await eventually(FakeGoogle.count("POST", "/lists/L1/tasks") == 1)
        await store.sync()
        XCTAssertEqual(FakeGoogle.count("GET", "/users/@me/lists"), before, "sync no pisa escrituras en vuelo")
        await add.value
        FakeGoogle.delay = 0
        await store.sync()
        XCTAssertEqual(FakeGoogle.count("GET", "/users/@me/lists"), before + 1)
        XCTAssertTrue(store.rows.contains { $0.task.title == "Slow" })
    }

    func testConcurrentSyncsCollapseIntoOne() async {
        await boot()
        let before = FakeGoogle.count("GET", "/users/@me/lists")
        FakeGoogle.delay = 0.1
        async let s1: () = store.sync()
        async let s2: () = store.sync()
        async let s3: () = store.sync()
        _ = await (s1, s2, s3)
        XCTAssertEqual(FakeGoogle.count("GET", "/users/@me/lists"), before + 1)
        XCTAssertFalse(store.isSyncing)
    }

    func testToggleIsOptimisticBeforeServerAnswers() async {
        await boot()
        FakeGoogle.delay = 0.2
        let t = store.task("b", in: "L1")!
        let job = Task { await store.toggle(t, in: "L1") }
        await Task.yield()
        XCTAssertTrue(store.task("b", in: "L1")!.isCompleted, "UI cambia al instante")
        await job.value
        XCTAssertTrue(store.task("b", in: "L1")!.isCompleted)
    }

    func testOptimisticToggleRollsBackWhenServerFailsLate() async {
        await boot()
        FakeGoogle.delay = 0.1
        FakeGoogle.failures = [500]
        let t = store.task("b", in: "L1")!
        let job = Task { await store.toggle(t, in: "L1") }
        await Task.yield()
        XCTAssertTrue(store.task("b", in: "L1")!.isCompleted)
        await job.value
        XCTAssertFalse(store.task("b", in: "L1")!.isCompleted)
        XCTAssertNotNil(store.notice)
    }

    func testOptimisticDeleteHidesRowImmediatelyAndSyncWaits() async {
        await boot()
        FakeGoogle.delay = 0.2
        let t = store.task("a", in: "L1")!
        let job = Task { await store.delete(t, in: "L1") }
        await Task.yield()
        XCTAssertEqual(store.rows.map(\.id), ["b"])
        let before = FakeGoogle.count("GET", "/users/@me/lists")
        await store.sync()
        XCTAssertEqual(FakeGoogle.count("GET", "/users/@me/lists"), before)
        await job.value
        XCTAssertEqual(store.rows.map(\.id), ["b"])
    }

    func testManyConcurrentAddsAllLand() async {
        await boot()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<10 { g.addTask { @MainActor in await self.store.add(title: "N\(i)") } }
        }
        XCTAssertEqual(store.rows.count, 12)
        XCTAssertEqual(FakeGoogle.titles("L1").count, 12)
    }

    func testDeleteCompletedBlocksSyncUntilDone() async {
        FakeGoogle.tasks["L1"]!.append(FakeGoogle.task("d", "D", status: "completed"))
        await boot()
        FakeGoogle.delay = 0.15
        let before = FakeGoogle.count("GET", "/users/@me/lists")
        let job = Task { await store.deleteCompleted() }
        await eventually(FakeGoogle.count("DELETE") == 1)
        await store.sync()
        XCTAssertEqual(FakeGoogle.count("GET", "/users/@me/lists"), before)
        await job.value
        XCTAssertEqual(store.completedCount, 0)
    }

    func testSelectingListsRapidlyEndsOnLastSelection() async {
        FakeGoogle.seed(list: "L2", "Home", tasks: [FakeGoogle.task("h", "H")])
        await boot()
        store.selectedListID = "L2"
        store.selectedListID = "L1"
        await eventually(!self.store.isSyncing)
        XCTAssertEqual(store.selectedListID, "L1")
        XCTAssertEqual(store.rows.map(\.id), ["a", "b"])
    }
}
