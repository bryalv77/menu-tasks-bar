import AppKit
import Combine
import SwiftUI

/// Borderless panel that can receive keyboard input (for the text fields).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let http: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private lazy var auth: AuthService = {
        #if DEBUG
        if Demo.isOn { return AuthService(http: http, storage: Demo.Storage()) }
        #endif
        return AuthService(http: http)
    }()
    private let settings = AppSettings()
    private lazy var store: TasksStore = {
        #if DEBUG
        if Demo.isOn { return TasksStore(repo: Demo.Repo(), settings: settings) }
        #endif
        return TasksStore(repo: TasksAPI(http: http, auth: auth), settings: settings)
    }()

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: KeyPanel!
    private var lastHidden = Date.distantPast
    private var lastSync = Date.distantPast
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ n: Notification) {
        // Panel is created once and reused: the view is already loaded when the icon is clicked.
        let host = NSHostingController(rootView: RootView(auth: auth, store: store))
        _ = host.view
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = 12
        host.view.layer?.masksToBounds = true
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentViewController = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        if let b = item.button {
            b.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Tasks")
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(toggle)
        }
        store.$badge.removeDuplicates()
            .sink { [weak self] n in self?.item.button?.title = n > 0 ? " \(n)" : "" }.store(in: &bag)

        if auth.isSignedIn { Task { await store.sync() } }
        // Google Tasks has no push: poll every 30 s while the panel is open and every 5 min in the background.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.auth.isSignedIn else { return }
                let every: TimeInterval = self.panel.isVisible ? 30 : 300
                if Date().timeIntervalSince(self.lastSync) >= every - 1 { self.refresh() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.auth.isSignedIn == true { self?.refresh() } }
        }
        auth.$isSignedIn.dropFirst().filter { $0 }.sink { [weak self] _ in Task { await self?.store.sync() } }.store(in: &bag)
        // Any sign-out (including the automatic one on invalid_grant) wipes the in-memory data and favorites.
        auth.$isSignedIn.dropFirst().filter { !$0 }.sink { [weak self] _ in self?.store.reset() }.store(in: &bag)
    }

    private func refresh() {
        lastSync = Date()
        Task { await store.sync() }
    }

    func windowDidResignKey(_ n: Notification) {
        panel.orderOut(nil)
        lastHidden = Date()
    }

    @objc private func toggle() {
        // If clicking the icon is what took focus from the panel, just close it.
        if panel.isVisible || Date().timeIntervalSince(lastHidden) < 0.2 { panel.orderOut(nil); return }
        guard let bw = item.button?.window else { return }
        let screen = bw.screen ?? NSScreen.main
        let vis = screen?.visibleFrame ?? .zero          // visibleFrame excludes the menu bar
        let size = panel.frame.size
        let x = min(max(bw.frame.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        let y = vis.maxY - size.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if auth.isSignedIn { refresh() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)      // no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
