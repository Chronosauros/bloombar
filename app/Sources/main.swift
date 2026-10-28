import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var np: NowPlaying?
    private var status: StatusController?
    private var poster: PosterController?
    private var auth: TidalAuth?
    private var favorites: FavoritesStore?
    private var bag = Set<AnyCancellable>()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    private let authItem = NSMenuItem(title: "Log In to TIDAL…", action: #selector(toggleAuth), keyEquivalent: "")
    private let progressItem = NSMenuItem(title: "Progress in Menu Bar", action: #selector(toggleProgress), keyEquivalent: "")

    /// Redirect URI tidalbar://callback wraca do aplikacji jako zdarzenie URL (bez Xcode, przez NSAppleEventManager).
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s), url.scheme?.lowercased() == "tidalbar" else { return }
        auth?.deliver(url)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let adapter = Adapter.bundled() else {
            let alert = NSAlert()
            alert.messageText = "bloombar is missing its MediaRemote adapter"
            alert.informativeText = "Rebuild the app with scripts/build-app.sh."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let np = NowPlaying(adapter: adapter)
        let auth = TidalAuth()
        let favorites = FavoritesStore(auth: auth)
        np.searchFallback = { [weak favorites] t in await favorites?.searchTrack(t) }
        // Po zalogowaniu zapas przez API staje sie dostepny, wiec grajacy utwor szukamy jeszcze raz.
        auth.$loggedIn.dropFirst().filter { $0 }.sink { [weak np] _ in np?.retryResolve() }.store(in: &bag)
        let poster = PosterController(np: np, favorites: favorites)
        let status = StatusController(np: np, menu: makeMenu()) { [weak self] in
            self?.poster?.toggle(below: self?.status?.item.button?.window)
        }
        self.np = np
        self.poster = poster
        self.status = status
        self.auth = auth
        self.favorites = favorites
        registerLoginItemOnce()
        np.start()
        favorites.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        np?.stop()
    }

    /// Pierwsze uruchomienie z /Applications wlacza start przy logowaniu (decyzja wlasciciela 27.10.2026);
    /// potem decyduje przelacznik w menu.
    private func registerLoginItemOnce() {
        let key = "loginItemConfigured"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("bloombar: login item registration failed: \(error)")
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let open = NSMenuItem(title: "Open TIDAL", action: #selector(openTidal), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        authItem.target = self
        menu.addItem(authItem)
        loginItem.target = self
        menu.addItem(loginItem)
        progressItem.target = self
        menu.addItem(progressItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit bloombar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        authItem.title = (auth?.loggedIn ?? false) ? "Log Out of TIDAL" : "Log In to TIDAL…"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        progressItem.state = (status?.progressEnabled ?? true) ? .on : .off
    }

    @objc private func toggleAuth() {
        guard let favorites else { return }
        if auth?.loggedIn == true {
            favorites.logOut()
        } else if !TidalConfig.isConfigured {
            let alert = NSAlert()
            alert.messageText = "TIDAL login is not configured"
            alert.informativeText = "Create an app on developer.tidal.com, put its Client ID in app/tidal.local.env (TIDAL_CLIENT_ID) and rebuild bloombar."
            alert.runModal()
        } else {
            Task { await favorites.logIn() }
        }
    }

    @objc private func toggleProgress() {
        guard let status else { return }
        status.progressEnabled.toggle()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("bloombar: login item change failed: \(error)")
        }
    }

    @objc private func openTidal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/TIDAL.app"))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
