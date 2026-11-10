import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private var client: SpotifyClient!
    private var bar: BarController!
    private var statusItem: NSStatusItem?
    private var screenChangeCount = 0
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        client = SpotifyClient()
        bar = BarController(client: client, settings: settings)
        DebugModes.attachDump(to: client, arguments: CommandLine.arguments)
        makeStatusItem()
        makeMainMenu()

        // Right-click anywhere on the bar for the same menu as the menu bar icon.
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, event.window === self.bar.panel, let view = self.bar.panel.contentView else { return event }
            NSMenu.popUpContextMenu(self.makeMenu(), with: event, for: view)
            return nil
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    // MARK: - Status item

    private func makeStatusItem() {
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "NowBar"
        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "NowBar")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// macOS sometimes leaves a status item off a newly attached display's menu bar, so rebuild it
    /// once the screens settle.
    private func screensChanged() {
        screenChangeCount += 1
        let count = screenChangeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, count == self.screenChangeCount else { return }
                self.bar.ensureOnScreen()
                self.makeStatusItem()
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // The app menu already has Quit, so only the menu bar icon's menu adds its own.
        for item in makeMenu(includeQuit: menu === statusItem?.menu).items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
    }

    // MARK: - Menu

    // MARK: - Dock

    /// Clicking the Dock icon brings the bar back, opening Spotify if it's closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !settings.showBar { settings.showBar = true }
        if !client.isRunning { client.openSpotify() }
        return false
    }

    /// Right-click on the Dock icon. The Dock adds its own Options and Quit.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        makeMenu(includeQuit: false)
    }

    /// The menus shown in the menu bar while NowBar is the active app.
    private func makeMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About NowBar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide NowBar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit NowBar", #selector(quit), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let barItem = NSMenuItem()
        let barMenu = NSMenu(title: "Bar")
        barMenu.delegate = self
        barItem.submenu = barMenu
        main.addItem(barItem)
        NSApp.mainMenu = main
    }

    private func makeMenu(includeQuit: Bool = true) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(statusLine())
        menu.addItem(.separator())

        menu.addItem(item("Show Bar When Spotify Is Open", #selector(toggleShowBar), checked: settings.showBar))
        menu.addItem(.separator())

        menu.addItem(header("Position"))
        menu.addItem(item("On Top of Windows", #selector(setOnTop), checked: settings.onTop))
        menu.addItem(item("On the Desktop, Behind Windows", #selector(setBehind), checked: !settings.onTop))
        menu.addItem(.separator())

        menu.addItem(header("Desktops"))
        menu.addItem(item("Show on All Desktops", #selector(toggleAllDesktops), checked: settings.allDesktops))
        let move = item("Move Bar to This Desktop", #selector(moveHere))
        move.isEnabled = !settings.allDesktops
        menu.addItem(move)
        menu.addItem(.separator())

        menu.addItem(item("Lock Position and Size", #selector(toggleLocked), checked: settings.locked))
        menu.addItem(item("Reset Position and Size", #selector(resetFrame)))
        menu.addItem(.separator())

        menu.addItem(item("Open at Login", #selector(toggleOpenAtLogin),
                          checked: SMAppService.mainApp.status == .enabled))
        if includeQuit {
            menu.addItem(.separator())
            menu.addItem(item("Quit NowBar", #selector(quit), key: "q"))
        }
        return menu
    }

    private func statusLine() -> NSMenuItem {
        if !client.isRunning {
            let line = item("Open Spotify", #selector(openSpotify))
            return line
        }
        if client.permission == .denied {
            return item("Allow NowBar to Control Spotify…", #selector(openAutomationSettings))
        }
        guard let track = client.playback.track else {
            let line = NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: "")
            line.isEnabled = false
            return line
        }
        let symbol = client.playback.state == .playing ? "▶︎" : "❚❚"
        let title = "\(symbol)  \(track.title) — \(track.artist)"
        return item(title.count > 60 ? String(title.prefix(59)) + "…" : title, #selector(openSpotify))
    }

    private func item(_ title: String, _ action: Selector, checked: Bool? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let checked { item.state = checked ? .on : .off }
        return item
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleShowBar() { settings.showBar.toggle() }
    @objc private func setOnTop() { settings.onTop = true }
    @objc private func setBehind() { settings.onTop = false }
    @objc private func toggleAllDesktops() { settings.allDesktops.toggle() }
    @objc private func moveHere() { bar.moveToCurrentDesktop() }
    @objc private func toggleLocked() { settings.locked.toggle() }
    @objc private func resetFrame() { bar.resetFrame() }
    @objc private func openSpotify() { client.openSpotify() }
    @objc private func openAutomationSettings() { SpotifyClient.openAutomationSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate()
            alert.runModal()
        }
    }
}
