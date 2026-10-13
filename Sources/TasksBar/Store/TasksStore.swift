import Foundation

@MainActor
final class TasksStore: ObservableObject {
    @Published private(set) var lists: [TaskList]
    @Published private(set) var rows: [TaskRow] = []
    @Published private(set) var isSyncing = false
    @Published var notice: String?
    @Published var selectedListID: String? {
        didSet { if oldValue != selectedListID { rebuildRows(); persist(); Task { await sync() } } }
    }

    private var tasksByList: [String: [GTask]]
    private let repo: TasksRepository

    var pendingCount: Int { rows.filter { !$0.task.isCompleted }.count }

    init(repo: TasksRepository) {
        self.repo = repo
        let snap = Cache.load()           // pinta desde caché antes de tocar la red
        lists = snap.lists
        tasksByList = snap.tasks
        selectedListID = snap.selectedListID ?? snap.lists.first?.id
        rebuildRows()
    }

    // MARK: Sync

    func sync() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remoteLists = try await repo.lists()
            lists = remoteLists
            if selectedListID == nil || !remoteLists.contains(where: { $0.id == selectedListID }) {
                selectedListID = remoteLists.first?.id
            }
            if let id = selectedListID {
                tasksByList[id] = try await repo.tasks(in: id)
            }
            rebuildRows()
            persist()
            notice = nil
        } catch is CancellationError {
        } catch AuthError.signedOut {
        } catch {
            notice = error.localizedDescription     // la caché sigue visible
        }
    }

    func reset() {
        lists = []; tasksByList = [:]; selectedListID = nil; rows = []
        Cache.clear()
    }

    // MARK: Interno

    private func rebuildRows() {
        rows = TaskRow.flatten(selectedListID.flatMap { tasksByList[$0] } ?? [])
    }

    private func persist() {
        Cache.save(Snapshot(lists: lists, tasks: tasksByList, selectedListID: selectedListID))
    }
}
