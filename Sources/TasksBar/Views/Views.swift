import SwiftUI

struct RootView: View {
    @ObservedObject var auth: AuthService
    @ObservedObject var store: TasksStore

    var body: some View {
        Group {
            if auth.isSignedIn { TasksView(store: store, auth: auth) }
            else { SignInView(auth: auth) }
        }
        .frame(width: 360, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SignInView: View {
    @ObservedObject var auth: AuthService
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Tasks Bar").font(.title2.bold())
            if Config.isConfigured {
                Button("Sign in with Google") {
                    Task {
                        do { try await auth.signIn(); error = nil }
                        catch AuthError.cancelled {}
                        catch let e { error = e.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("Missing Client ID.\nBuild with scripts/build.sh (see README).").multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let lists: [TaskList]
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { close() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text("Settings").font(.headline)
                Spacer()
            }.padding(10)
            Divider()
            Form {
                Picker("Tab on open", selection: $settings.defaultListID) {
                    Text("First list").tag("")
                    Text("Favorites").tag(TasksStore.favoritesID)
                    ForEach(lists) { Text($0.title).tag($0.id) }
                }
                Toggle("Show subtasks", isOn: $settings.showSubtasks)
                Toggle("Show completed", isOn: $settings.showCompleted)
                if settings.showCompleted {
                    Picker("Completed since", selection: $settings.completedDays) {
                        Text("Today").tag(0)
                        Text("Yesterday").tag(1)
                        Text("3 days ago").tag(3)
                        Text("7 days ago").tag(7)
                        Text("30 days ago").tag(30)
                        Text("Always").tag(-1)
                    }
                    Picker("Maximum completed", selection: $settings.maxCompleted) {
                        ForEach([5, 10, 25, 50], id: \.self) { Text("\($0)").tag($0) }
                        Text("No limit").tag(0)
                    }
                }
                Toggle("Counter in the menu bar", isOn: $settings.showBadge)
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                if let e = settings.launchError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            Spacer()
        }
    }
}

struct FooterLabel: View {
    let icon: String
    let label: String
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 19))
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(hovering ? Color.primary : .secondary)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct FooterButton: View {
    let icon: String
    let label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { FooterLabel(icon: icon, label: label) }.buttonStyle(.plain)
    }
}

struct StarButton: View {
    let on: Bool
    var size: CGFloat = 14
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: on ? "star.fill" : "star")
                .font(.system(size: size))
                .foregroundStyle(on ? Color.yellow : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Remove from favorites" : "Mark as favorite")
    }
}

struct TaskRowView: View {
    let row: TaskRow
    let isFavorite: Bool
    let minutes: Int?
    var toggle: () -> Void
    var toggleFavorite: () -> Void
    var edit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: toggle) {
                Image(systemName: row.task.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.task.isCompleted ? Color.accentColor : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(row.task.isCompleted ? "Mark as pending" : "Mark as completed")

            Text(row.task.title.isEmpty ? "(untitled)" : row.task.title)
                .strikethrough(row.task.isCompleted)
                .foregroundStyle(row.task.isCompleted ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let due = row.task.dueLabel(minutes: minutes) {
                Text(due).font(.caption.weight(.medium)).monospacedDigit()
                    .foregroundStyle(row.task.isOverdue(minutes: minutes) ? Color.red : .secondary)
            }
            // Space is always reserved: the row doesn't change size on hover.
            StarButton(on: isFavorite, action: toggleFavorite)
                .opacity(isFavorite || hovering ? 1 : 0)
                .allowsHitTesting(isFavorite || hovering)
        }
        .padding(.leading, CGFloat(row.depth) * 20)
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: edit)
    }
}

struct ListEditor: View {
    enum Outcome { case save(String), deleteList, clearCompleted, cancel }
    let list: TaskList?
    let completedCount: Int
    var done: (Outcome) -> Void
    @State private var title: String
    @State private var confirmDelete = false
    @State private var confirmClear = false

    init(list: TaskList?, completedCount: Int, done: @escaping (Outcome) -> Void) {
        self.list = list; self.completedCount = completedCount; self.done = done
        _title = State(initialValue: list?.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { done(.cancel) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(list == nil ? "New list" : "Edit list").font(.headline)
                Spacer()
                Button(list == nil ? "Create" : "Save") { done(.save(title)) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }.padding(10)
            Divider()
            Form {
                TextField("Name", text: $title)
                if list != nil {
                    Section {
                        Button(confirmClear ? "Sure? Press again to delete them" : "Delete completed tasks (\(completedCount))", role: .destructive) {
                            if confirmClear { done(.clearCompleted) } else { confirmClear = true; confirmDelete = false }
                        }
                        .disabled(completedCount == 0)
                        Button(confirmDelete ? "Sure? Press again to delete the list" : "Delete list", role: .destructive) {
                            if confirmDelete { done(.deleteList) } else { confirmDelete = true; confirmClear = false }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Spacer()
        }
    }
}

func minutesOfDay(_ d: Date) -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

func dateFromMinutes(_ m: Int?) -> Date {
    let m = m ?? 9 * 60
    return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
}

/// Screen to create a new task.
struct NewTaskView: View {
    struct Values { var title: String; var notes: String; var due: Date?; var minutes: Int? }
    var done: (Values?) -> Void
    @State private var title = ""
    @State private var notes = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var hasTime = false
    @State private var time = dateFromMinutes(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { done(nil) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text("New task").font(.headline)
                Spacer()
                Button("Create") {
                    done(Values(title: title, notes: notes, due: hasDue ? due : nil,
                                minutes: hasDue && hasTime ? minutesOfDay(time) : nil))
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }.padding(10)
            Divider()
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Details", text: $notes, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Date", selection: $due, displayedComponents: .date)
                        Toggle("Time", isOn: $hasTime)
                        if hasTime { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute) }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)
        }
    }
}

/// Detail of a task or subtask. Fields save themselves on exit; subtask actions apply instantly.
struct TaskDetail: View {
    @ObservedObject var store: TasksStore
    let listID: String
    let taskID: String
    var open: (String) -> Void
    var back: () -> Void

    @State private var title: String
    @State private var notes: String
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var newSub = ""
    @State private var confirmDelete = false
    @State private var skipCommit = false

    init(store: TasksStore, listID: String, taskID: String, open: @escaping (String) -> Void, back: @escaping () -> Void) {
        self.store = store; self.listID = listID; self.taskID = taskID; self.open = open; self.back = back
        let t = store.task(taskID, in: listID)
        let m = store.minutes(for: taskID)
        _title = State(initialValue: t?.title ?? "")
        _notes = State(initialValue: t?.notes ?? "")
        _hasDue = State(initialValue: t?.dueDay != nil)
        _due = State(initialValue: t?.dueDay ?? Date())
        _hasTime = State(initialValue: m != nil)
        _time = State(initialValue: dateFromMinutes(m))
    }

    var body: some View {
        if let t = store.task(taskID, in: listID) { content(t) }
        else { Color.clear.onAppear { back() } }     // deleted from another device
    }

    private func content(_ t: GTask) -> some View {
        let isSub = t.parent != nil
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { back() } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Text(isSub ? "Subtask" : "Task").font(.headline)
                Spacer()
                StarButton(on: store.isFavorite(taskID), size: 17) { store.toggleFavorite(t, in: listID) }
            }.padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            Form {
                Section {
                    TextField("Title", text: $title).onSubmit { back() }
                    TextField("Details", text: $notes, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Toggle("Due date", isOn: $hasDue)
                    if hasDue {
                        DatePicker("Date", selection: $due, displayedComponents: .date)
                        Toggle("Time", isOn: $hasTime)
                        if hasTime { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute) }
                    }
                }
                if !isSub {
                    Section("Subtasks") {
                        ForEach(store.subtasks(of: taskID, in: listID)) { sub in subtaskRow(sub) }
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            TextField("Add subtask", text: $newSub).textFieldStyle(.plain)
                                .onSubmit {
                                    let s = newSub; newSub = ""
                                    Task { await store.add(title: s, parent: taskID, in: listID) }
                                }
                        }
                    }
                }
                Section {
                    Button(confirmDelete ? "Sure? Press again to delete" : (isSub ? "Delete subtask" : "Delete task"), role: .destructive) {
                        if confirmDelete {
                            skipCommit = true
                            Task { await store.delete(t, in: listID) }
                            back()
                        } else { confirmDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: .infinity)
        }
        .onDisappear { if !skipCommit { commit() } }
    }

    private func subtaskRow(_ sub: GTask) -> some View {
        let m = store.minutes(for: sub.id)
        return HStack(spacing: 8) {
            Button { Task { await store.toggle(sub, in: listID) } } label: {
                Image(systemName: sub.isCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(sub.isCompleted ? Color.accentColor : .secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { open(sub.id) } label: {
                HStack {
                    Text(sub.title.isEmpty ? "(untitled)" : sub.title)
                        .strikethrough(sub.isCompleted).foregroundStyle(sub.isCompleted ? .secondary : .primary)
                    Spacer(minLength: 4)
                    if let d = sub.dueLabel(minutes: m) {
                        Text(d).font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(sub.isOverdue(minutes: m) ? Color.red : .secondary)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            StarButton(on: store.isFavorite(sub.id)) { store.toggleFavorite(sub, in: listID) }
        }
    }

    private func commit() {
        guard let t = store.task(taskID, in: listID) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let newDue = hasDue ? due : nil
        let newMin = hasDue && hasTime ? minutesOfDay(time) : nil
        if t.isUnchanged(title: trimmed, notes: notes, due: newDue, minutes: newMin, storedMinutes: store.minutes(for: taskID)) { return }
        Task { await store.edit(t, in: listID, title: trimmed, notes: notes, due: newDue, minutes: newMin) }
    }
}

struct DetailRoute: Equatable {
    var listID: String
    var path: [String]      // task → subtask
}

struct TasksView: View {
    @ObservedObject var store: TasksStore
    @ObservedObject var auth: AuthService
    @State private var showSettings = false
    @State private var detail: DetailRoute?
    @State private var creating = false
    @State private var creatingList = false
    @State private var renamingList: TaskList?
    @State private var newTitle = ""

    var body: some View {
        if creatingList { ListEditor(list: nil, completedCount: 0) { r in
            creatingList = false
            if case .save(let t) = r { Task { await store.addList(title: t) } }
        } }
        else if let l = renamingList { ListEditor(list: l, completedCount: store.completedCount) { r in
            renamingList = nil
            switch r {
            case .save(let t): Task { await store.renameList(l, to: t) }
            case .deleteList: Task { await store.deleteList(l) }
            case .clearCompleted: Task { await store.deleteCompleted() }
            case .cancel: break
            }
        } }
        else if creating { NewTaskView { v in
            creating = false
            if let v { Task { await store.add(title: v.title, notes: v.notes, due: v.due, minutes: v.minutes) } }
        } }
        else if let d = detail, let id = d.path.last {
            TaskDetail(store: store, listID: d.listID, taskID: id,
                       open: { detail?.path.append($0) },
                       back: { if (detail?.path.count ?? 0) > 1 { detail?.path.removeLast() } else { detail = nil } })
                .id(id)
        }
        else if showSettings { SettingsView(settings: store.settings, lists: store.lists) { showSettings = false } }
        else { content }
    }

    private var isFavorites: Bool { store.selectedListID == TasksStore.favoritesID }

    private var editListButton: some View {
        Button {
            renamingList = store.lists.first { $0.id == store.selectedListID }
        } label: {
            Label("Edit list", systemImage: "pencil").font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.selectedListID == nil)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        let favOn = store.selectedListID == TasksStore.favoritesID
                        Button { store.selectedListID = TasksStore.favoritesID } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(Color.yellow)
                                Text("Favorites").font(.system(size: 13, weight: favOn ? .semibold : .regular)).lineLimit(1)
                            }
                            .foregroundStyle(favOn ? Color.primary : .secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(favOn ? Color.primary.opacity(0.12) : .clear))
                            .contentShape(Capsule())
                        }.buttonStyle(.plain)
                        ForEach(store.lists) { l in
                            let on = l.id == store.selectedListID
                            Button { store.selectedListID = l.id } label: {
                                Text(l.title).font(.system(size: 13, weight: on ? .semibold : .regular)).lineLimit(1)
                                    .foregroundStyle(on ? Color.primary : .secondary)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(on ? Color.primary.opacity(0.12) : .clear))
                                    .contentShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                if store.isSyncing { ProgressView().controlSize(.small).padding(.horizontal, 4) }
                Button { creatingList = true } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 30, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("New list")
            }
            .padding(10)
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField(isFavorites ? "New favorite task" : "New task", text: $newTitle)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let t = newTitle; newTitle = ""
                        Task { await store.add(title: t) }
                    }
            }
            .padding(10)

            Divider()

            if store.rows.isEmpty {
                Spacer(); Text(store.isSyncing ? "Loading…" : (isFavorites ? "No favorites" : "No tasks")).foregroundStyle(.secondary); Spacer()
                if !isFavorites { editListButton }
            } else {
                List {
                    ForEach(store.rows) { row in
                        TaskRowView(row: row, isFavorite: store.isFavorite(row.task.id), minutes: store.minutes(for: row.task.id),
                                    toggle: { Task { await store.toggle(row.task, in: row.listID) } },
                                    toggleFavorite: { store.toggleFavorite(row.task, in: row.listID) },
                                    edit: { detail = DetailRoute(listID: row.listID, path: [row.task.id]) })
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    }
                    if !isFavorites {
                        editListButton
                            .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: .infinity)
            }

            if let n = store.notice {
                Divider()
                Text(n).font(.caption).foregroundStyle(.orange).lineLimit(2).padding(6)
            }

            Divider()
            HStack(spacing: 4) {
                FooterButton(icon: "plus.circle", label: "New") { creating = true }
                FooterButton(icon: "arrow.clockwise", label: "Sync") { Task { await store.sync() } }
                FooterButton(icon: "gearshape", label: "Settings") { showSettings = true }
                Menu {
                    Button("Sign out of Google") { auth.signOut(); store.reset() }
                    Divider()
                    Button("Quit Tasks Bar") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { FooterLabel(icon: "ellipsis.circle", label: "More") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
    }
}

extension GTask {
    private var dueDate: Date? {
        guard let due, due.count >= 10 else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: String(due.prefix(10)))
    }

    /// Due date as a local calendar day (Google stores it as midnight UTC).
    var dueDay: Date? {
        guard let d = dueDate else { return nil }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day], from: d)
        return Calendar.current.date(from: c)
    }

    var isOverdue: Bool {
        guard !isCompleted, let d = dueDay else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    var dueLabel: String? {
        guard let d = dueDay else { return nil }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Does the edit form change nothing? (avoids a pointless PATCH).
    func isUnchanged(title: String, notes newNotes: String, due newDue: Date?, minutes newMin: Int?, storedMinutes: Int?) -> Bool {
        let sameDue: Bool
        switch (dueDay, newDue) {
        case (nil, nil): sameDue = true
        case let (a?, b?): sameDue = Calendar.current.isDate(a, inSameDayAs: b)
        default: sameDue = false
        }
        return title == self.title && newNotes == (notes ?? "") && sameDue && newMin == storedMinutes
    }

    func dueLabel(minutes: Int?) -> String? {
        guard let base = dueLabel else { return nil }
        guard let m = minutes else { return base }
        return String(format: "%@ %02d:%02d", base, m / 60, m % 60)
    }

    func isOverdue(minutes: Int?) -> Bool {
        guard !isCompleted, let d = dueDay else { return false }
        let cal = Calendar.current
        if d < cal.startOfDay(for: Date()) { return true }
        if let m = minutes, cal.isDateInToday(d), let t = cal.date(byAdding: .minute, value: m, to: d) { return t < Date() }
        return false
    }
}
