import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let http: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private lazy var auth = AuthService(http: http)
    private lazy var store = TasksStore(repo: TasksAPI(http: http, auth: auth))

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        // Panel precreado y reutilizado: la vista ya está cargada cuando se hace click.
        let host = NSHostingController(rootView: RootView(auth: auth, store: store))
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        _ = host.view

        if let b = item.button {
            b.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Tasks")
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(toggle)
        }
        store.$rows.map { _ in self.store.pendingCount }.removeDuplicates()
            .sink { [weak self] n in self?.item.button?.title = n > 0 ? " \(n)" : "" }.store(in: &bag)

        if auth.isSignedIn { Task { await store.sync() } }
        auth.$isSignedIn.dropFirst().filter { $0 }.sink { [weak self] _ in Task { await self?.store.sync() } }.store(in: &bag)
    }

    @objc private func toggle() {
        if popover.isShown { popover.performClose(nil); return }
        guard let b = item.button else { return }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        if auth.isSignedIn { Task { await store.sync() } }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)      // sin icono en el Dock
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
