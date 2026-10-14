import XCTest
@testable import TasksBar

private let settingKeys = ["showSubtasks", "showCompleted", "completedDays", "maxCompleted", "showBadge", "defaultListID"]

@MainActor
final class SettingsAndMetaTests: XCTestCase {
    override func setUp() {
        FakeGoogle.reset()
        settingKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.removeObject(forKey: "localMeta")
        Cache.clear()
    }

    func testDefaults() {
        let s = AppSettings()
        XCTAssertTrue(s.showSubtasks); XCTAssertTrue(s.showCompleted); XCTAssertTrue(s.showBadge)
        XCTAssertEqual(s.completedDays, 1); XCTAssertEqual(s.maxCompleted, 10); XCTAssertEqual(s.defaultListID, "")
    }

    func testSettingsPersistAcrossInstances() {
        let s = AppSettings()
        s.showSubtasks = false; s.showCompleted = false; s.showBadge = false
        s.completedDays = -1; s.maxCompleted = 0; s.defaultListID = TasksStore.favoritesID
        let r = AppSettings()
        XCTAssertFalse(r.showSubtasks); XCTAssertFalse(r.showCompleted); XCTAssertFalse(r.showBadge)
        XCTAssertEqual(r.completedDays, -1); XCTAssertEqual(r.maxCompleted, 0); XCTAssertEqual(r.defaultListID, TasksStore.favoritesID)
    }

    func testLocalMetaRoundTripAndCorruptData() {
        XCTAssertEqual(LocalMeta.load(), LocalMeta())
        var m = LocalMeta(); m.favorites["t"] = "L"; m.minutes["t"] = 90
        m.save()
        XCTAssertEqual(LocalMeta.load(), m)
        UserDefaults.standard.set(Data("garbage".utf8), forKey: "localMeta")
        XCTAssertEqual(LocalMeta.load(), LocalMeta())
    }

    func testFavoritesAndMinutesSurviveRestart() async {
        FakeGoogle.seed(list: "L1", "W", tasks: [FakeGoogle.task("a", "A")])
        let repo = TasksAPI(http: FakeGoogle.session) { _ in "t" }
        let s1 = TasksStore(repo: repo, settings: AppSettings())
        await s1.sync()
        s1.toggleFavorite(s1.task("a", in: "L1")!, in: "L1")
        await s1.edit(s1.task("a", in: "L1")!, in: "L1", title: "A", notes: "", due: Date(), minutes: 600)
        let s2 = TasksStore(repo: repo, settings: AppSettings())
        XCTAssertTrue(s2.isFavorite("a")); XCTAssertEqual(s2.minutes(for: "a"), 600)
    }

    func testChangingSettingsRebuildsRowsLive() async {
        FakeGoogle.seed(list: "L1", "W", tasks: [FakeGoogle.task("a", "A", pos: "1"), FakeGoogle.task("a1", "A1", parent: "a", pos: "1")])
        let settings = AppSettings()
        let store = TasksStore(repo: TasksAPI(http: FakeGoogle.session) { _ in "t" }, settings: settings)
        await store.sync()
        XCTAssertEqual(store.rows.count, 2)
        settings.showSubtasks = false
        for _ in 0..<50 where store.rows.count != 1 { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.rows.count, 1)
        settings.showBadge = false
        for _ in 0..<50 where store.badge != 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(store.badge, 0)
    }
}

/// Pure logic used by the views (due dates, labels, change detection).
final class ViewLogicTests: XCTestCase {
    private let cal = Calendar.current
    private func task(due: Date?, status: String = "needsAction", title: String = "T", notes: String? = nil) -> GTask {
        var j: [String: Any] = ["id": "x", "title": title, "status": status]
        if let due { j["due"] = TasksAPI.dueString(due) }
        if let notes { j["notes"] = notes }
        return try! JSONDecoder().decode(GTask.self, from: JSONSerialization.data(withJSONObject: j))
    }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))! }

    func testDueDayRoundTripsLocalCalendarDay() {
        XCTAssertEqual(task(due: day(3)).dueDay, day(3))
        XCTAssertNil(task(due: nil).dueDay)
    }

    func testDueLabels() {
        XCTAssertEqual(task(due: day(0)).dueLabel, "Today")
        XCTAssertEqual(task(due: day(1)).dueLabel, "Tomorrow")
        XCTAssertEqual(task(due: day(-1)).dueLabel, "Yesterday")
        XCTAssertNotNil(task(due: day(20)).dueLabel)
        XCTAssertNil(task(due: nil).dueLabel)
        XCTAssertEqual(task(due: day(0)).dueLabel(minutes: 545), "Today 09:05")
        XCTAssertEqual(task(due: day(0)).dueLabel(minutes: nil), "Today")
    }

    func testOverdue() {
        XCTAssertTrue(task(due: day(-1)).isOverdue)
        XCTAssertFalse(task(due: day(0)).isOverdue)
        XCTAssertFalse(task(due: day(1)).isOverdue)
        XCTAssertFalse(task(due: day(-5), status: "completed").isOverdue, "completadas nunca vencen")
        XCTAssertFalse(task(due: nil).isOverdue)
    }

    func testOverdueWithTimeToday() throws {
        XCTAssertTrue(task(due: day(0)).isOverdue(minutes: 0) || minutesOfDay(Date()) == 0)
        try XCTSkipIf(minutesOfDay(Date()) >= 23 * 60 + 59, "too close to midnight")
        XCTAssertFalse(task(due: day(0)).isOverdue(minutes: 23 * 60 + 59))
        XCTAssertTrue(task(due: day(-1)).isOverdue(minutes: 23 * 60 + 59))
        XCTAssertFalse(task(due: day(1)).isOverdue(minutes: 0))
    }

    func testMinutesHelpers() {
        XCTAssertEqual(minutesOfDay(dateFromMinutes(750)), 750)
        XCTAssertEqual(minutesOfDay(dateFromMinutes(nil)), 540, "defaults to 09:00")
    }

    func testIsUnchangedDetectsEachField() {
        let t = task(due: day(2), title: "T", notes: "n")
        XCTAssertTrue(t.isUnchanged(title: "T", notes: "n", due: day(2), minutes: 60, storedMinutes: 60))
        XCTAssertFalse(t.isUnchanged(title: "U", notes: "n", due: day(2), minutes: 60, storedMinutes: 60))
        XCTAssertFalse(t.isUnchanged(title: "T", notes: "", due: day(2), minutes: 60, storedMinutes: 60))
        XCTAssertFalse(t.isUnchanged(title: "T", notes: "n", due: day(3), minutes: 60, storedMinutes: 60))
        XCTAssertFalse(t.isUnchanged(title: "T", notes: "n", due: nil, minutes: 60, storedMinutes: 60))
        XCTAssertFalse(t.isUnchanged(title: "T", notes: "n", due: day(2), minutes: 61, storedMinutes: 60))
        XCTAssertTrue(task(due: nil).isUnchanged(title: "T", notes: "", due: nil, minutes: nil, storedMinutes: nil))
    }
}
