import Foundation
import ServiceManagement

/// Preferencias persistidas en UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var showSubtasks: Bool { didSet { d.set(showSubtasks, forKey: "showSubtasks") } }
    @Published var showCompleted: Bool { didSet { d.set(showCompleted, forKey: "showCompleted") } }
    /// Días hacia atrás desde el inicio de hoy: 0 = solo hoy, 1 = desde ayer, -1 = todas.
    @Published var completedDays: Int { didSet { d.set(completedDays, forKey: "completedDays") } }
    /// Máximo de completadas visibles; 0 = sin límite.
    @Published var maxCompleted: Int { didSet { d.set(maxCompleted, forKey: "maxCompleted") } }
    @Published var showBadge: Bool { didSet { d.set(showBadge, forKey: "showBadge") } }
    /// Pestaña que se abre al iniciar: "" = primera lista, "__favorites__" = Favoritas, o el id de una lista.
    @Published var defaultListID: String { didSet { d.set(defaultListID, forKey: "defaultListID") } }

    init() {
        d.register(defaults: ["showSubtasks": true, "showCompleted": true, "completedDays": 1, "maxCompleted": 10, "showBadge": true])
        showSubtasks = d.bool(forKey: "showSubtasks")
        showCompleted = d.bool(forKey: "showCompleted")
        completedDays = d.integer(forKey: "completedDays")
        maxCompleted = d.integer(forKey: "maxCompleted")
        showBadge = d.bool(forKey: "showBadge")
        defaultListID = d.string(forKey: "defaultListID") ?? ""
    }

    /// Iniciar al encender el Mac. El estado real lo guarda macOS (SMAppService), no UserDefaults.
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchError: String?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
