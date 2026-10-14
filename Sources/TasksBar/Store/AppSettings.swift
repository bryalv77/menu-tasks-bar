import Foundation
import ServiceManagement

/// Preferences persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var showSubtasks: Bool { didSet { d.set(showSubtasks, forKey: "showSubtasks") } }
    @Published var showCompleted: Bool { didSet { d.set(showCompleted, forKey: "showCompleted") } }
    /// Days back from the start of today: 0 = only today, 1 = since yesterday, -1 = all.
    @Published var completedDays: Int { didSet { d.set(completedDays, forKey: "completedDays") } }
    /// Maximum visible completed tasks; 0 = no limit.
    @Published var maxCompleted: Int { didSet { d.set(maxCompleted, forKey: "maxCompleted") } }
    @Published var showBadge: Bool { didSet { d.set(showBadge, forKey: "showBadge") } }
    /// Tab opened at launch: "" = first list, "__favorites__" = Favorites, or a list id.
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

    /// Launch at login. The real state is kept by macOS (SMAppService), not UserDefaults.
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
