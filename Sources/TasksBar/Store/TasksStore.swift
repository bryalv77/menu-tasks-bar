import Combine
import Foundation

@MainActor
final class TasksStore: ObservableObject {
    /// Pestaña virtual con las tareas marcadas como favoritas (de todas las listas).
    static let favoritesID = "__favorites__"

    @Published private(set) var lists: [TaskList]
    @Published private(set) var rows: [TaskRow] = []
    @Published private(set) var badge = 0
    @Published private(set) var isSyncing = false
    @Published private(set) var meta: LocalMeta
    @Published private(set) var tasksByList: [String: [GTask]]
    @Published var notice: String?
    @Published var selectedListID: String? {
        didSet { if oldValue != selectedListID { rebuildRows(); persist(); Task { await sync() } } }
    }

    let settings: AppSettings
    private let repo: TasksRepository
    private var pendingWrites = 0     // sync se pospone mientras hay escrituras en vuelo (evita pisar cambios optimistas)
    private var bag = Set<AnyCancellable>()

    init(repo: TasksRepository, settings: AppSettings) {
        self.repo = repo
        self.settings = settings
        let snap = Cache.load()           // pinta desde caché antes de tocar la red
        lists = snap.lists
        tasksByList = snap.tasks
        meta = LocalMeta.load()
        selectedListID = Self.initialSelection(settings.defaultListID, lists: snap.lists)
        rebuildRows()
        // objectWillChange se emite ANTES del cambio: reconstruimos en el siguiente ciclo.
        settings.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.rebuildRows() }
        }.store(in: &bag)
    }

    private static func initialSelection(_ pref: String, lists: [TaskList]) -> String? {
        if pref == favoritesID { return favoritesID }
        if lists.contains(where: { $0.id == pref }) { return pref }
        return lists.first?.id
    }

    // MARK: Consultas

    func task(_ id: String, in listID: String) -> GTask? {
        tasksByList[listID]?.first { $0.id == id }
    }

    func subtasks(of id: String, in listID: String) -> [GTask] {
        (tasksByList[listID] ?? []).filter { $0.parent == id }.sorted { ($0.position ?? "") < ($1.position ?? "") }
    }

    func isFavorite(_ id: String) -> Bool { meta.favorites[id] != nil }
    func minutes(for id: String) -> Int? { meta.minutes[id] }

    var completedCount: Int {
        (selectedListID.flatMap { tasksByList[$0] } ?? []).filter(\.isCompleted).count
    }

    // MARK: Sync

    func sync() async {
        guard !isSyncing, pendingWrites == 0 else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remoteLists = try await repo.lists()
            lists = remoteLists
            let valid = Set(remoteLists.map(\.id))
            if selectedListID == nil || (selectedListID != Self.favoritesID && !valid.contains(selectedListID!)) {
                selectedListID = Self.initialSelection(settings.defaultListID, lists: remoteLists)
            }
            // Lista seleccionada + las listas que contienen favoritas.
            var toFetch = Set(meta.favorites.values).intersection(valid)
            if let s = selectedListID, valid.contains(s) { toFetch.insert(s) }
            for id in toFetch.sorted() {
                let fetched = try await repo.tasks(in: id)
                tasksByList[id] = fetched
                let present = Set(fetched.map(\.id))
                // Favoritas cuya tarea ya no existe (borrada desde otro dispositivo).
                meta.favorites = meta.favorites.filter { $0.value != id || present.contains($0.key) }
            }
            tasksByList = tasksByList.filter { valid.contains($0.key) }
            meta.save()
            rebuildRows()
            persist()
            notice = nil
        } catch is CancellationError {
        } catch AuthError.signedOut {
        } catch {
            notice = error.localizedDescription     // la caché sigue visible
        }
    }

    // MARK: Tareas

    func toggle(_ t: GTask, in lid: String) async {
        let done = !t.isCompleted
        let stamp = ISO8601DateFormatter.withFraction.string(from: Date())
        mutate(t.id, in: lid) { $0.status = done ? "completed" : "needsAction"; $0.completed = done ? stamp : nil }
        let patch: [String: Any] = done ? ["status": "completed"] : ["status": "needsAction", "completed": NSNull()]
        await apply(patch, to: t.id, in: lid, rollback: t)
    }

    /// Crea una tarea (o subtarea si hay `parent`). Sin `listID`: la lista seleccionada; en Favoritas, la primera lista y queda marcada.
    func add(title: String, notes: String = "", due: Date? = nil, minutes: Int? = nil,
             parent: String? = nil, in listID: String? = nil, favorite: Bool = false) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let lid: String
        var fav = favorite
        if let l = listID { lid = l }
        else if let s = selectedListID, s != Self.favoritesID { lid = s }
        else if let f = lists.first?.id { lid = f; fav = true }
        else { return }
        // Las subtareas nuevas se agregan al final.
        let previous = parent == nil ? nil : subtasks(of: parent!, in: lid).last?.id
        pendingWrites += 1; defer { pendingWrites -= 1 }
        do {
            let t = try await repo.create(in: lid, title: title, notes: notes, due: due, parent: parent, previous: previous)
            tasksByList[lid, default: []].append(t)
            if fav { meta.favorites[t.id] = lid }
            if due != nil, let m = minutes { meta.minutes[t.id] = m }
            meta.save()
            rebuildRows(); persist(); notice = nil
        } catch { notice = error.localizedDescription }
    }

    func edit(_ t: GTask, in lid: String, title: String, notes: String, due: Date?, minutes: Int?) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let dueStr = due.map(TasksAPI.dueString)
        mutate(t.id, in: lid) { $0.title = title; $0.notes = notes.isEmpty ? nil : notes; $0.due = dueStr }
        if let m = minutes, due != nil { meta.minutes[t.id] = m } else { meta.minutes[t.id] = nil }
        meta.save()
        rebuildRows()
        let patch: [String: Any] = ["title": title, "notes": notes, "due": dueStr as Any? ?? NSNull()]
        await apply(patch, to: t.id, in: lid, rollback: t)
    }

    func toggleFavorite(_ t: GTask, in lid: String) {
        if meta.favorites[t.id] != nil { meta.favorites[t.id] = nil } else { meta.favorites[t.id] = lid }
        meta.save()
        rebuildRows()
    }

    func delete(_ t: GTask, in lid: String) async {
        pendingWrites += 1; defer { pendingWrites -= 1 }
        let backup = tasksByList[lid], oldMeta = meta
        let gone = Set([t.id] + (tasksByList[lid] ?? []).filter { $0.parent == t.id }.map(\.id))
        tasksByList[lid]?.removeAll { gone.contains($0.id) }
        gone.forEach { meta.favorites[$0] = nil; meta.minutes[$0] = nil }
        meta.save()
        rebuildRows()
        do { try await repo.delete(in: lid, taskID: t.id); persist(); notice = nil }
        catch {
            tasksByList[lid] = backup; meta = oldMeta; meta.save()
            rebuildRows()
            notice = error.localizedDescription
        }
    }

    /// Borra definitivamente todas las completadas de la lista seleccionada (también las ocultas).
    func deleteCompleted() async {
        guard let lid = selectedListID, lid != Self.favoritesID else { return }
        let ids = (tasksByList[lid] ?? []).filter(\.isCompleted).map(\.id)
        guard !ids.isEmpty else { return }
        pendingWrites += 1
        let backup = tasksByList[lid]
        let gone = Set(ids)
        tasksByList[lid]?.removeAll { gone.contains($0.id) }
        rebuildRows()
        let repo = self.repo
        let failed = await withTaskGroup(of: Bool.self) { g -> Int in
            for id in ids { g.addTask { (try? await repo.delete(in: lid, taskID: id)) == nil } }
            return await g.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        pendingWrites -= 1
        if failed > 0 {
            if tasksByList[lid] != nil, let backup { tasksByList[lid] = backup }
            rebuildRows()
            notice = "No se pudieron eliminar \(failed) tareas."
            await sync()
        } else {
            gone.forEach { meta.favorites[$0] = nil; meta.minutes[$0] = nil }
            meta.save()
            rebuildRows(); persist(); notice = nil
        }
    }

    // MARK: Listas

    func addList(title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        pendingWrites += 1; defer { pendingWrites -= 1 }
        do {
            let l = try await repo.createList(title: title)
            lists.append(l)
            tasksByList[l.id] = []
            selectedListID = l.id
            notice = nil
        } catch { notice = error.localizedDescription }
    }

    func renameList(_ l: TaskList, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = lists.firstIndex(where: { $0.id == l.id }) else { return }
        pendingWrites += 1; defer { pendingWrites -= 1 }
        lists[i].title = title
        do { _ = try await repo.renameList(id: l.id, title: title); persist(); notice = nil }
        catch {
            if let j = lists.firstIndex(where: { $0.id == l.id }) { lists[j].title = l.title }
            notice = error.localizedDescription
        }
    }

    func deleteList(_ l: TaskList) async {
        pendingWrites += 1; defer { pendingWrites -= 1 }
        let oldLists = lists, oldTasks = tasksByList[l.id], oldSel = selectedListID, oldMeta = meta
        lists.removeAll { $0.id == l.id }
        tasksByList[l.id] = nil
        meta.favorites = meta.favorites.filter { $0.value != l.id }
        meta.save()
        if selectedListID == l.id { selectedListID = lists.first?.id }
        do { try await repo.deleteList(id: l.id); persist(); notice = nil }
        catch {
            lists = oldLists; tasksByList[l.id] = oldTasks; selectedListID = oldSel; meta = oldMeta; meta.save()
            rebuildRows()
            notice = error.localizedDescription
        }
    }

    func reset() {
        lists = []; tasksByList = [:]; selectedListID = nil; rows = []
        meta = LocalMeta(); meta.save()
        Cache.clear()
    }

    // MARK: Interno

    private func mutate(_ id: String, in lid: String, _ f: (inout GTask) -> Void) {
        guard let i = tasksByList[lid]?.firstIndex(where: { $0.id == id }) else { return }
        f(&tasksByList[lid]![i])
        rebuildRows()
    }

    /// Envía el PATCH; si falla restaura la tarea anterior.
    private func apply(_ patch: [String: Any], to id: String, in lid: String, rollback old: GTask) async {
        pendingWrites += 1; defer { pendingWrites -= 1 }
        do {
            let r = try await repo.update(in: lid, taskID: id, patch: patch)
            mutate(id, in: lid) { $0 = r }
            persist(); notice = nil
        } catch {
            mutate(id, in: lid) { $0 = old }
            notice = error.localizedDescription
        }
    }

    private func rebuildRows() {
        var all: [TaskRow]
        if selectedListID == Self.favoritesID {
            // Todas las favoritas (también subtareas), sin sangría y agrupadas por lista.
            all = lists.flatMap { l in TaskRow.flatten(tasksByList[l.id] ?? [], listID: l.id) }
                .filter { meta.favorites[$0.task.id] != nil }
                .map { TaskRow(task: $0.task, depth: 0, listID: $0.listID) }
        } else {
            let lid = selectedListID ?? ""
            all = TaskRow.flatten(tasksByList[lid] ?? [], listID: lid)
            if !settings.showSubtasks { all = all.filter { $0.depth == 0 } }
        }

        badge = settings.showBadge ? all.filter { !$0.task.isCompleted }.count : 0

        // Completadas: ventana de días + máximo (las más recientes primero).
        var allowed = Set<String>()
        if settings.showCompleted {
            var done = all.map(\.task).filter(\.isCompleted)
            if settings.completedDays >= 0 {
                let cutoff = Calendar.current.date(byAdding: .day, value: -settings.completedDays,
                                                   to: Calendar.current.startOfDay(for: Date()))!
                done = done.filter { ($0.completedDate ?? .distantPast) >= cutoff }
            }
            done.sort { ($0.completedDate ?? .distantPast) > ($1.completedDate ?? .distantPast) }
            if settings.maxCompleted > 0 { done = Array(done.prefix(settings.maxCompleted)) }
            allowed = Set(done.map(\.id))
        }
        rows = all.filter { !$0.task.isCompleted || allowed.contains($0.id) }
    }

    private func persist() {
        Cache.save(Snapshot(lists: lists, tasks: tasksByList, selectedListID: selectedListID))
    }
}

extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
