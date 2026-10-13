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
                Button("Iniciar sesión con Google") {
                    Task {
                        do { try await auth.signIn(); error = nil }
                        catch AuthError.cancelled {}
                        catch let e { error = e.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("Falta el Client ID.\nEdítalo en Sources/TasksBar/Config.swift").multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal) }
        }
    }
}

struct TasksView: View {
    @ObservedObject var store: TasksStore
    @ObservedObject var auth: AuthService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $store.selectedListID) {
                    ForEach(store.lists) { Text($0.title).tag(Optional($0.id)) }
                }
                .labelsHidden().frame(maxWidth: 220)
                Spacer()
                if store.isSyncing { ProgressView().controlSize(.small) }
                Button { Task { await store.sync() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Sincronizar")
                Button("Salir") { auth.signOut(); store.reset() }.buttonStyle(.borderless).font(.caption)
            }
            .padding(10)
            Divider()

            if store.rows.isEmpty {
                Spacer(); Text(store.isSyncing ? "Cargando…" : "Sin tareas").foregroundStyle(.secondary); Spacer()
            } else {
                List(store.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.task.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(row.task.isCompleted ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.task.title.isEmpty ? "(sin título)" : row.task.title)
                                .strikethrough(row.task.isCompleted)
                                .foregroundStyle(row.task.isCompleted ? .secondary : .primary)
                            if let due = row.task.dueLabel { Text(due).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * 20)
                }
                .listStyle(.plain)
            }

            if let n = store.notice {
                Divider()
                Text(n).font(.caption).foregroundStyle(.orange).lineLimit(2).padding(6)
            }
        }
    }
}

extension GTask {
    var dueLabel: String? {
        guard let due, due.count >= 10 else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: String(due.prefix(10))) else { return nil }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }
}
