import XCTest
@testable import TasksBar

/// E2E sin red real: Store → TasksAPI → URLSession → FakeGoogle.
@MainActor
final class StoreTests: XCTestCase {
    private let fav = TasksStore.favoritesID
    private var store: TasksStore!

    override func setUp() {
        FakeGoogle.reset()
        for k in ["showSubtasks", "showCompleted", "completedDays", "maxCompleted", "showBadge", "defaultListID"] {
            UserDefaults.standard.removeObject(forKey: k)
        }
        LocalMeta().save()
        Cache.clear()
    }

    /// Crea el store contra el servidor falso y sincroniza.
    private func boot(_ configure: (AppSettings) -> Void = { _ in }) async {
        let s = AppSettings(); configure(s)
        store = TasksStore(repo: TasksAPI(http: FakeGoogle.session) { _ in "tok" }, settings: s)
        await store.sync()
    }

    private func seedStandard() {
        FakeGoogle.seed(list: "L1", "Work", tasks: [
            FakeGoogle.task("a", "A", pos: "01"),
            FakeGoogle.task("a1", "A1", parent: "a", pos: "01"),
            FakeGoogle.task("b", "B", pos: "02"),
        ])
        FakeGoogle.seed(list: "L2", "Home", tasks: [FakeGoogle.task("h", "H")])
    }

    private func eventually(_ c: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 { if c() { return }; try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTFail("timeout", file: file, line: line)
    }

    private func titles() -> [String] { store.rows.map(\.task.title) }
    private func t(_ id: String, _ lid: String = "L1") -> GTask { store.task(id, in: lid)! }

    // MARK: Sync / listados

    func testSyncLoadsListsAndSelectedListRows() async {
        seedStandard(); await boot()
        XCTAssertEqual(store.lists.map(\.title), ["Work", "Home"])
        XCTAssertEqual(store.selectedListID, "L1")
        XCTAssertEqual(titles(), ["A", "A1", "B"])
        XCTAssertEqual(store.rows.map(\.depth), [0, 1, 0])
        XCTAssertNil(store.tasksByList["L2"], "solo se descarga la lista seleccionada")
        XCTAssertNil(store.notice)
    }

    func testSyncPaginatesLargeLists() async {
        FakeGoogle.pageSize = 2
        FakeGoogle.seed(list: "L1", "Big", tasks: (1...5).map { FakeGoogle.task("t\($0)", "T\($0)", pos: "0\($0)") })
        await boot()
        XCTAssertEqual(titles(), ["T1", "T2", "T3", "T4", "T5"])
    }

    func testDefaultListPreferenceIsUsed() async {
        seedStandard(); await boot { $0.defaultListID = "L2" }
        XCTAssertEqual(store.selectedListID, "L2")
        XCTAssertEqual(titles(), ["H"])
    }

    func testSelectingListFetchesItsTasks() async {
        seedStandard(); await boot()
        store.selectedListID = "L2"
        await eventually(self.titles() == ["H"])
    }

    func testOfflineKeepsCacheAndShowsNoticeThenRecovers() async {
        seedStandard(); await boot()
        await Task.yield()
        FakeGoogle.offline = true
        await store.sync()
        XCTAssertEqual(store.notice, "Sin conexión.")
        XCTAssertEqual(titles(), ["A", "A1", "B"])
        FakeGoogle.offline = false
        await store.sync()
        XCTAssertNil(store.notice)
    }

    func testRemoteChangesArePulledOnSync() async {
        seedStandard(); await boot()
        FakeGoogle.tasks["L1"]!.append(FakeGoogle.task("c", "C", pos: "03"))
        FakeGoogle.tasks["L1"]!.removeAll { $0["id"] as? String == "b" }
        await store.sync()
        XCTAssertEqual(titles(), ["A", "A1", "C"])
    }

    func testListDeletedRemotelyReselectsFirst() async {
        seedStandard(); await boot { $0.defaultListID = "L2" }
        FakeGoogle.lists.removeAll { $0["id"] as? String == "L2" }
        await store.sync()
        XCTAssertEqual(store.selectedListID, "L1")
        XCTAssertNil(store.tasksByList["L2"])
    }

    func testCachePaintsBeforeNetwork() async {
        seedStandard(); await boot()
        await eventually(Cache.load().tasks["L1"]?.count == 3)
        let s2 = TasksStore(repo: TasksAPI(http: FakeGoogle.session) { _ in "t" }, settings: AppSettings())
        XCTAssertEqual(s2.rows.map(\.task.title), ["A", "A1", "B"])
    }

    func testResetClearsEverything() async {
        seedStandard(); await boot()
        store.toggleFavorite(t("a"), in: "L1")
        store.reset()
        XCTAssertTrue(store.lists.isEmpty); XCTAssertTrue(store.rows.isEmpty); XCTAssertTrue(store.meta.favorites.isEmpty)
    }

    func testCompletedWindowMaxAndToggle() async {
        let old = ISO8601DateFormatter.withFraction.string(from: Date().addingTimeInterval(-10 * 86400))
        let now = ISO8601DateFormatter.withFraction.string(from: Date())
        var oldT = FakeGoogle.task("o", "Old", status: "completed"); oldT["completed"] = old
        var n1 = FakeGoogle.task("n1", "New1", status: "completed"); n1["completed"] = now
        var n2 = FakeGoogle.task("n2", "New2", status: "completed"); n2["completed"] = now
        FakeGoogle.seed(list: "L1", "L", tasks: [FakeGoogle.task("p", "Pending"), oldT, n1, n2])

        await boot { $0.completedDays = 1; $0.maxCompleted = 10 }
        XCTAssertEqual(Set(titles()), ["Pending", "New1", "New2"], "la completada antigua queda fuera de la ventana")
        XCTAssertEqual(store.completedCount, 3, "completedCount cuenta todas, visibles o no")

        let s = AppSettings(); s.completedDays = -1; s.maxCompleted = 1
        store = TasksStore(repo: TasksAPI(http: FakeGoogle.session) { _ in "t" }, settings: s)
        await store.sync()
        XCTAssertEqual(titles().count, 2, "pendiente + 1 completada (máximo)")

        let s2 = AppSettings(); s2.showCompleted = false
        store = TasksStore(repo: TasksAPI(http: FakeGoogle.session) { _ in "t" }, settings: s2)
        await store.sync()
        XCTAssertEqual(titles(), ["Pending"])
    }

    func testBadgeCountsPendingAndHonorsSetting() async {
        seedStandard(); await boot()
        XCTAssertEqual(store.badge, 3)
        let s = AppSettings(); s.showBadge = false
        store = TasksStore(repo: TasksAPI(http: FakeGoogle.session) { _ in "t" }, settings: s)
        await store.sync()
        XCTAssertEqual(store.badge, 0)
    }

    func testHideSubtasksSetting() async {
        seedStandard(); await boot { $0.showSubtasks = false }
        XCTAssertEqual(titles(), ["A", "B"])
    }

    // MARK: CRUD de tareas

    func testAddTaskTrimsAndPersistsRemotely() async {
        seedStandard(); await boot()
        await store.add(title: "  New  ", notes: "n")
        XCTAssertEqual(titles().first, "New", "Google inserta arriba")
        XCTAssertEqual(FakeGoogle.titles("L1").last, "New")
        XCTAssertEqual(FakeGoogle.requests.last?.body["notes"] as? String, "n")
    }

    func testAddBlankTitleDoesNothing() async {
        seedStandard(); await boot()
        let n = FakeGoogle.requests.count
        await store.add(title: "   ")
        XCTAssertEqual(FakeGoogle.requests.count, n)
    }

    func testAddWithDueAndMinutesStoresLocalMinutes() async {
        seedStandard(); await boot()
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        await store.add(title: "Meet", due: due, minutes: 540)
        let id = store.rows.first!.id
        XCTAssertEqual(store.minutes(for: id), 540)
        XCTAssertEqual(t(id).due, "2026-05-01T00:00:00.000Z")
        await store.add(title: "NoDue", minutes: 60)
        XCTAssertNil(store.minutes(for: store.rows.first!.id), "minutos sin fecha se ignoran")
    }

    func testAddFailureShowsNoticeAndAddsNothing() async {
        seedStandard(); await boot()
        FakeGoogle.failures = [500]
        await store.add(title: "X")
        XCTAssertNotNil(store.notice)
        XCTAssertEqual(titles(), ["A", "A1", "B"])
    }

    func testEditUpdatesLocallyAndRemotely() async {
        seedStandard(); await boot()
        let due = Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 2))!
        await store.edit(t("a"), in: "L1", title: " A+ ", notes: "memo", due: due, minutes: 90)
        XCTAssertEqual(t("a").title, "A+")
        XCTAssertEqual(t("a").notes, "memo")
        XCTAssertEqual(t("a").due, "2026-06-02T00:00:00.000Z")
        XCTAssertEqual(store.minutes(for: "a"), 90)
        XCTAssertEqual(FakeGoogle.titles("L1").first, "A+")

        await store.edit(t("a"), in: "L1", title: "A+", notes: "", due: nil, minutes: 90)
        XCTAssertNil(t("a").due); XCTAssertTrue(t("a").notes?.isEmpty ?? true)
        XCTAssertNil(store.minutes(for: "a"), "sin fecha se borra la hora")
    }

    func testEditFailureRollsBack() async {
        seedStandard(); await boot()
        FakeGoogle.failures = [500]
        await store.edit(t("a"), in: "L1", title: "Changed", notes: "", due: nil, minutes: nil)
        XCTAssertEqual(t("a").title, "A")
        XCTAssertNotNil(store.notice)
    }

    func testToggleCompleteAndReopen() async {
        seedStandard(); await boot()
        await store.toggle(t("b"), in: "L1")
        XCTAssertTrue(t("b").isCompleted)
        XCTAssertEqual(FakeGoogle.tasks["L1"]!.first { $0["id"] as? String == "b" }?["status"] as? String, "completed")
        XCTAssertEqual(store.badge, 2)
        await store.toggle(t("b"), in: "L1")
        XCTAssertFalse(t("b").isCompleted)
        XCTAssertNil(t("b").completed)
        XCTAssertEqual(store.badge, 3)
    }

    func testToggleFailureRollsBack() async {
        seedStandard(); await boot()
        FakeGoogle.failures = [500]
        await store.toggle(t("b"), in: "L1")
        XCTAssertFalse(t("b").isCompleted)
        XCTAssertNotNil(store.notice)
    }

    func testDeleteTaskRemovesSubtasksAndMeta() async {
        seedStandard(); await boot()
        store.toggleFavorite(t("a1"), in: "L1")
        await store.delete(t("a"), in: "L1")
        XCTAssertEqual(titles(), ["B"])
        XCTAssertEqual(FakeGoogle.titles("L1"), ["B"])
        XCTAssertFalse(store.isFavorite("a1"))
    }

    func testDeleteFailureRestores() async {
        seedStandard(); await boot()
        store.toggleFavorite(t("a"), in: "L1")
        FakeGoogle.failures = [500]
        await store.delete(t("a"), in: "L1")
        XCTAssertEqual(titles(), ["A", "A1", "B"])
        XCTAssertTrue(store.isFavorite("a"))
        XCTAssertNotNil(store.notice)
    }

    func testDeleteCompletedRemovesOnlyCompleted() async {
        FakeGoogle.seed(list: "L1", "L", tasks: [
            FakeGoogle.task("a", "A"), FakeGoogle.task("d1", "D1", status: "completed"), FakeGoogle.task("d2", "D2", status: "completed"),
        ])
        await boot()
        await store.deleteCompleted()
        XCTAssertEqual(FakeGoogle.titles("L1"), ["A"])
        XCTAssertEqual(store.completedCount, 0)
        XCTAssertNil(store.notice)
    }

    func testDeleteCompletedPartialFailureReportsAndResyncs() async {
        FakeGoogle.seed(list: "L1", "L", tasks: [
            FakeGoogle.task("d1", "D1", status: "completed"), FakeGoogle.task("d2", "D2", status: "completed"),
        ])
        await boot()
        FakeGoogle.failures = [500]
        await store.deleteCompleted()
        XCTAssertEqual(FakeGoogle.titles("L1").count, 1, "una falló en el servidor")
        XCTAssertEqual(store.completedCount, 1, "tras el resync coincide con el servidor")
    }

    // MARK: Subtareas

    func testAddSubtaskGoesAfterLastSiblingAndIndents() async {
        seedStandard(); await boot()
        await store.add(title: "A2", parent: "a", in: "L1")
        XCTAssertEqual(titles(), ["A", "A1", "A2", "B"])
        XCTAssertEqual(store.rows.map(\.depth), [0, 1, 1, 0])
        let r = FakeGoogle.requests.last!
        XCTAssertEqual(r.query["parent"], "a"); XCTAssertEqual(r.query["previous"], "a1")
        XCTAssertEqual(store.subtasks(of: "a", in: "L1").map(\.title), ["A1", "A2"])
    }

    func testFirstSubtaskHasNoPrevious() async {
        seedStandard(); await boot()
        await store.add(title: "B1", parent: "b", in: "L1")
        XCTAssertNil(FakeGoogle.requests.last!.query["previous"])
    }

    func testSubtaskEditToggleDelete() async {
        seedStandard(); await boot()
        await store.edit(t("a1"), in: "L1", title: "A1x", notes: "", due: nil, minutes: nil)
        await store.toggle(t("a1"), in: "L1")
        XCTAssertTrue(t("a1").isCompleted); XCTAssertEqual(t("a1").title, "A1x")
        XCTAssertEqual(t("a1").parent, "a")
        await store.delete(t("a1"), in: "L1")
        XCTAssertEqual(titles(), ["A", "B"])
        XCTAssertTrue(store.subtasks(of: "a", in: "L1").isEmpty)
    }

    // MARK: Favoritas

    func testToggleFavoriteOnOffAndPersists() async {
        seedStandard(); await boot()
        store.toggleFavorite(t("a"), in: "L1")
        XCTAssertTrue(store.isFavorite("a"))
        XCTAssertEqual(LocalMeta.load().favorites["a"], "L1")
        store.toggleFavorite(t("a"), in: "L1")
        XCTAssertFalse(store.isFavorite("a"))
        XCTAssertTrue(LocalMeta.load().favorites.isEmpty)
    }

    func testFavoritesTabSpansListsFlatAndFetchesOtherLists() async {
        seedStandard(); await boot()
        store.toggleFavorite(t("a1"), in: "L1")
        store.selectedListID = "L2"; await eventually(self.store.task("h", in: "L2") != nil)
        store.toggleFavorite(t("h", "L2"), in: "L2")
        store.selectedListID = fav
        await eventually(self.titles() == ["A1", "H"])
        XCTAssertEqual(store.rows.map(\.depth), [0, 0], "sin sangría")
        XCTAssertEqual(store.rows.map(\.listID), ["L1", "L2"])
        XCTAssertEqual(store.badge, 2)

        // Nueva sesión: la lista L2 no está seleccionada pero sus favoritas se descargan al sincronizar.
        FakeGoogle.tasks["L2"]!.append(FakeGoogle.task("h2", "H2"))
        await store.sync()
        XCTAssertNotNil(store.task("h2", in: "L2"))
    }

    func testAddInFavoritesTabGoesToFirstListMarkedFavorite() async {
        seedStandard(); await boot { $0.defaultListID = TasksStore.favoritesID }
        XCTAssertEqual(store.selectedListID, fav)
        await store.add(title: "Quick")
        XCTAssertTrue(FakeGoogle.titles("L1").contains("Quick"))
        XCTAssertEqual(titles(), ["Quick"])
        XCTAssertTrue(store.isFavorite(store.rows[0].id))
    }

    func testFavoriteForRemotelyDeletedTaskIsPruned() async {
        seedStandard(); await boot()
        store.toggleFavorite(t("b"), in: "L1")
        FakeGoogle.tasks["L1"]!.removeAll { $0["id"] as? String == "b" }
        await store.sync()
        XCTAssertFalse(store.isFavorite("b"))
    }

    func testAddFavoriteFlag() async {
        seedStandard(); await boot()
        await store.add(title: "Star", favorite: true)
        XCTAssertTrue(store.isFavorite(store.rows.first!.id))
    }

    // MARK: CRUD de listas

    func testAddListSelectsIt() async {
        seedStandard(); await boot()
        await store.addList(title: " Ideas ")
        XCTAssertEqual(store.lists.last?.title, "Ideas")
        XCTAssertEqual(store.selectedListID, store.lists.last?.id)
        XCTAssertEqual(FakeGoogle.lists.last?["title"] as? String, "Ideas")
        XCTAssertTrue(store.rows.isEmpty)
    }

    func testAddBlankListIgnored() async {
        seedStandard(); await boot()
        await store.addList(title: "  ")
        XCTAssertEqual(store.lists.count, 2)
    }

    func testRenameListSuccessAndFailure() async {
        seedStandard(); await boot()
        await store.renameList(store.lists[0], to: "Trabajo")
        XCTAssertEqual(store.lists[0].title, "Trabajo")
        XCTAssertEqual(FakeGoogle.lists[0]["title"] as? String, "Trabajo")

        FakeGoogle.failures = [500]
        await store.renameList(store.lists[0], to: "Otro")
        XCTAssertEqual(store.lists[0].title, "Trabajo", "rollback")
        XCTAssertNotNil(store.notice)

        let n = FakeGoogle.requests.count
        await store.renameList(store.lists[0], to: " ")
        XCTAssertEqual(FakeGoogle.requests.count, n)
    }

    func testDeleteListSelectsFirstAndDropsItsFavorites() async {
        seedStandard(); await boot { $0.defaultListID = "L2" }
        store.toggleFavorite(t("h", "L2"), in: "L2")
        await store.deleteList(store.lists[1])
        XCTAssertEqual(store.lists.map(\.id), ["L1"])
        XCTAssertEqual(store.selectedListID, "L1")
        XCTAssertFalse(store.isFavorite("h"))
        XCTAssertEqual(FakeGoogle.lists.count, 1)
    }

    func testDeleteListFailureRestoresEverything() async {
        seedStandard(); await boot()
        store.toggleFavorite(t("a"), in: "L1")
        FakeGoogle.failures = [500]
        await store.deleteList(store.lists[0])
        XCTAssertEqual(store.lists.count, 2)
        XCTAssertEqual(store.selectedListID, "L1")
        XCTAssertTrue(store.isFavorite("a"))
        XCTAssertEqual(titles(), ["A", "A1", "B"])
        XCTAssertNotNil(store.notice)
    }
}
