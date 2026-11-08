import AppKit
import Network
import ServiceManagement

/// Menu de la barre des menus. Aucun timer : le menu est reconstruit uniquement
/// à son ouverture, et l'état ne bouge que sur les notifications système (réveil, réseau, montage).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let netfs = NetFSBackend()
    private var shares: [Share] = []
    private var configDate: Date?
    private var pending = Set<String>()
    private var lastError: String?
    private let pathMonitor = NWPathMonitor()
    private var autoMountWork: DispatchWorkItem?
    private let routeQueue = DispatchQueue(label: "ShareBar.route") // getaddrinfo peut bloquer (noms .local)
    private var routes = [String: String]()   // hôte → adresse locale de la route actuelle (absent = pas de route)
    private var routeChanged = Set<String>()  // hôtes dont la route a changé depuis le dernier autoMount

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "externaldrive.connected.to.line.below",
                          accessibilityDescription: "ShareBar")
        img?.isTemplate = true
        statusItem.button?.image = img
        menu.delegate = self
        statusItem.menu = menu

        reloadConfigIfNeeded()
        // Événement système, pas de polling. Se déclenche aussi au lancement dès que le réseau
        // est prêt : couvre le démarrage de session avant que le Wi-Fi soit connecté.
        // Les mises à jour arrivent en rafale (utun, iCloud Relay…) : on ne monte que si la route
        // vers un NAS a changé (Wi-Fi revenu, VPN connecté), jamais s'il n'y a aucune route.
        pathMonitor.pathUpdateHandler = { [weak self] _ in self?.refreshRoutes() }
        pathMonitor.start(queue: .main)

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(updateTooltip), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(updateTooltip), name: NSWorkspace.didUnmountNotification, object: nil)
        updateTooltip()
    }

    // MARK: Config

    private func reloadConfigIfNeeded() {
        let date = ConfigStore.modificationDate()
        guard date == nil || date != configDate else { return }
        do {
            shares = try ConfigStore.load()
            configDate = ConfigStore.modificationDate()
            refreshRoutes() // nouveaux hôtes éventuels
            if lastError?.hasPrefix("Config") == true { lastError = nil }
        } catch {
            lastError = "Config invalide : \(error.localizedDescription)"
        }
    }

    private func backend(for share: Share) -> MountBackend {
        netfs // un seul backend pour l'instant ; router ici selon share.type plus tard
    }

    // MARK: Montage

    @objc private func didWake() {
        // La veille a pu démonter les partages sans changer la route : on retente tous les hôtes routables.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            self.routeChanged.formUnion(self.routes.keys)
            self.scheduleAutoMount()
        }
    }

    private func refreshRoutes() {
        let hosts = Set(shares.filter(\.autoMount).map(\.host))
        routeQueue.async { [weak self] in
            let found = Dictionary(uniqueKeysWithValues: hosts.compactMap { h in Route.source(to: h).map { (h, $0) } })
            DispatchQueue.main.async {
                guard let self else { return }
                for (h, src) in found where self.routes[h] != src { self.routeChanged.insert(h) }
                self.routes = found
                if !self.routeChanged.isEmpty { self.scheduleAutoMount() }
            }
        }
    }

    /// Regroupe les rafales d'événements en un seul autoMount, 3 s après le dernier.
    private func scheduleAutoMount() {
        autoMountWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoMount() }
        autoMountWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func autoMount() {
        let hosts = routeChanged.intersection(routes.keys)
        routeChanged.removeAll()
        let mounted = Volumes.mounted()
        for s in shares where s.autoMount && hosts.contains(s.host) && mounted[s.id] == nil {
            mount(s, userInitiated: false)
        }
    }

    private static let retryDelay: TimeInterval = 10

    private func mount(_ s: Share, userInitiated: Bool) {
        guard !pending.contains(s.id) else { return }
        pending.insert(s.id)
        attempt(s, userInitiated: userInitiated, left: s.mountAttempts)
    }

    /// Le partage reste dans `pending` pendant toute la série de tentatives.
    private func attempt(_ s: Share, userInitiated: Bool, left: Int) {
        // Route perdue pendant les tentatives auto : on arrête, le moniteur relancera au retour.
        guard userInitiated || routes[s.host] != nil else { pending.remove(s.id); updateTooltip(); return }
        let mount = { [weak self] in
            guard let self else { return }
            self.backend(for: s).mount(s, allowUI: userInitiated) { [weak self] result in
                self?.finish(s, userInitiated: userInitiated, left: left, result: result)
            }
        }
        if userInitiated { return mount() }
        // Comme le ping de ConnectMeNow : NetFS peut bloquer des minutes sur un serveur absent.
        Probe.tcp(host: s.host, port: s.type.port) { [weak self] ok in
            if ok { mount() } else { self?.finish(s, userInitiated: false, left: left, result: .failure(MountError(code: EHOSTUNREACH))) }
        }
    }

    private func finish(_ s: Share, userInitiated: Bool, left: Int, result: Result<URL?, Error>) {
        if case .failure(let e) = result, left > 1, (e as? MountError)?.isRetryable ?? true {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelay) { [weak self] in
                self?.attempt(s, userInitiated: userInitiated, left: left - 1)
            }
            return
        }
        pending.remove(s.id)
        switch result {
        case .success(let url):
            lastError = nil
            if let url = url ?? Volumes.mounted()[s.id], s.openOnMount || userInitiated { NSWorkspace.shared.open(url) }
        case .failure(let e):
            if (e as? MountError)?.isCancel != true { lastError = "\(s.name) : \(e.localizedDescription)" }
        }
        updateTooltip()
    }

    private func unmount(_ url: URL, name: String) {
        Volumes.unmount(url) { [weak self] err in
            if let err { self?.lastError = "\(name) : \(err.localizedDescription)" }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        reloadConfigIfNeeded()
        menu.removeAllItems()
        let mounted = Volumes.mounted()

        if shares.isEmpty {
            menu.addItem(disabled("Aucun partage configuré"))
        }
        for (i, s) in shares.enumerated() {
            let isMounted = mounted[s.id] != nil
            let title = pending.contains(s.id) ? "\(s.name) …" : s.name
            let item = NSMenuItem(title: title, action: #selector(shareClicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = isMounted ? .on : .off
            item.toolTip = isMounted ? "Clic : ouvrir · ⌥ clic : démonter" : "Clic : monter"
            menu.addItem(item)
            if isMounted {
                let alt = NSMenuItem(title: "Démonter \(s.name)", action: #selector(unmountClicked(_:)), keyEquivalent: "")
                alt.target = self
                alt.tag = i
                alt.isAlternate = true
                alt.keyEquivalentModifierMask = .option
                menu.addItem(alt)
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("Tout monter", #selector(mountAll)))
        menu.addItem(action("Tout démonter", #selector(unmountAll)))
        menu.addItem(.separator())
        if let lastError { menu.addItem(disabled("⚠︎ \(lastError)")) }
        menu.addItem(action("Modifier les partages…", #selector(editConfig)))
        let login = action("Ouvrir au démarrage", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(action("Quitter", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func action(_ title: String, _ sel: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = target ?? self
        return it
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    @objc private func shareClicked(_ item: NSMenuItem) {
        guard shares.indices.contains(item.tag) else { return }
        let s = shares[item.tag]
        if let url = Volumes.mounted()[s.id] { NSWorkspace.shared.open(url) } else { mount(s, userInitiated: true) }
    }

    @objc private func unmountClicked(_ item: NSMenuItem) {
        guard shares.indices.contains(item.tag) else { return }
        let s = shares[item.tag]
        if let url = Volumes.mounted()[s.id] { unmount(url, name: s.name) }
    }

    @objc private func mountAll() {
        let mounted = Volumes.mounted()
        for s in shares where mounted[s.id] == nil { mount(s, userInitiated: false) }
    }

    @objc private func unmountAll() {
        let mounted = Volumes.mounted()
        for s in shares { if let url = mounted[s.id] { unmount(url, name: s.name) } }
    }

    @objc private func editConfig() {
        reloadConfigIfNeeded() // crée le fichier exemple s'il manque
        let file = ConfigStore.file
        if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { lastError = "Démarrage auto : \(error.localizedDescription)" }
    }

    @objc private func updateTooltip() {
        let mounted = Volumes.mounted()
        let n = shares.filter { mounted[$0.id] != nil }.count
        statusItem?.button?.toolTip = "ShareBar – \(n)/\(shares.count) monté(s)"
    }
}
