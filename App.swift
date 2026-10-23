import AppKit
import IOKit.ps
import ServiceManagement
import UniformTypeIdentifiers

enum AppPaths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/LoopPaper")
    static let library = support.appendingPathComponent("library")
}

enum Prefs {
    static let d = UserDefaults.standard
    static var current: String? { get { d.string(forKey: "current") } set { d.set(newValue, forKey: "current") } }
    static var slotID: String? { get { d.string(forKey: "slotID") } set { d.set(newValue, forKey: "slotID") } }
    static var lockScreen: Bool { get { d.object(forKey: "lockScreen") as? Bool ?? true } set { d.set(newValue, forKey: "lockScreen") } }
    static var userPaused: Bool { get { d.bool(forKey: "userPaused") } set { d.set(newValue, forKey: "userPaused") } }
    static var pauseOnBattery: Bool { get { d.object(forKey: "pauseOnBattery") as? Bool ?? true } set { d.set(newValue, forKey: "pauseOnBattery") } }
    static var toldAboutSettings: Bool { get { d.bool(forKey: "toldAboutSettings") } set { d.set(newValue, forKey: "toldAboutSettings") } }
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        // Test hook: LoopPaper --convert <input> <output.mov> <thumb.png>
        let args = CommandLine.arguments
        if args.count == 5, args[1] == "--convert" {
            do {
                try Converter().convert(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
                                        thumbnail: URL(fileURLWithPath: args[4])) { p in
                    FileHandle.standardError.write("\r\(Int(p * 100))%".data(using: .utf8)!)
                }
                print("\ndone")
                exit(0)
            } catch {
                print("\nerror: \(error.localizedDescription)")
                exit(1)
            }
        }
        // Test hooks: --lock <clip.mov> <thumb.png> <aerialID>, --restore
        if args.count == 5, args[1] == "--lock" {
            let a = Aerial(id: args[4], name: args[4])
            do { try LockScreen.apply(slot: a, video: URL(fileURLWithPath: args[2]), thumbnail: URL(fileURLWithPath: args[3])); print("swapped"); exit(0) }
            catch { print("error: \(error.localizedDescription)"); exit(1) }
        }
        if args.count == 2, args[1] == "--restore" {
            do { try LockScreen.restore(); print("restored"); exit(0) }
            catch { print("error: \(error.localizedDescription)"); exit(1) }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let desktop = DesktopPlayer()
    private var locked = false
    private var asleep = false
    private var onBattery = false
    private var busy = false

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(at: AppPaths.library, withIntermediateDirectories: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "LoopPaper")
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = true; self?.updatePlayback() }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.asleep = false; self?.updatePlayback(); self?.refreshLockScreen() }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshLockScreen() }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = true; self?.updatePlayback(); self?.refreshLockScreen() }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in self?.locked = false; self?.updatePlayback() }
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkPower() }
        checkPower()

        if let path = Prefs.current, FileManager.default.fileExists(atPath: path) {
            desktop.play(URL(fileURLWithPath: path))
        }
        updatePlayback()
    }

    // MARK: Playback state

    private var refreshGeneration = 0

    /// On macOS 26 the lock screen shows black for a swapped Aerial unless the wallpaper
    /// process reloads it, so restart it a second after each lock or wake (bursts collapse to one).
    private func refreshLockScreen() {
        guard !LockScreen.swappedIDs().isEmpty else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, generation == self.refreshGeneration else { return }
            DispatchQueue.global(qos: .userInitiated).async { LockScreen.restartWallpaper() }
        }
    }

    private func checkPower() {
        let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String?
        let now = type == kIOPSBatteryPowerValue
        if now != onBattery { onBattery = now; updatePlayback() }
    }

    private func updatePlayback() {
        let pause = Prefs.userPaused || locked || asleep || (onBattery && Prefs.pauseOnBattery)
        desktop.setPaused(pause)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let choose = item("Choose GIF or Video…", #selector(chooseFile), key: "o")
        choose.isEnabled = !busy
        menu.addItem(choose)

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for url in libraryClips().prefix(12) {
            let i = item(url.deletingPathExtension().lastPathComponent, #selector(pickRecent(_:)))
            i.representedObject = url
            i.state = url.path == Prefs.current ? .on : .off
            i.isEnabled = !busy
            if let img = NSImage(contentsOf: url.deletingPathExtension().appendingPathExtension("png")) {
                img.size = NSSize(width: 43, height: 26)
                i.image = img
            }
            sub.addItem(i)
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: "Nothing yet", action: nil, keyEquivalent: "")) }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())

        let pause = item(Prefs.userPaused ? "Resume Desktop Video" : "Pause Desktop Video", #selector(togglePause))
        pause.isEnabled = desktop.url != nil
        menu.addItem(pause)
        let battery = item("Pause on Battery", #selector(toggleBattery))
        battery.state = Prefs.pauseOnBattery ? .on : .off
        menu.addItem(battery)
        let stop = item("Turn Off Desktop Video", #selector(stopDesktop))
        stop.isEnabled = desktop.url != nil
        menu.addItem(stop)
        menu.addItem(.separator())

        let lock = item("Also Use on Lock Screen", #selector(toggleLock))
        lock.state = Prefs.lockScreen ? .on : .off
        menu.addItem(lock)
        let slotItem = NSMenuItem(title: "Lock Screen Slot", action: nil, keyEquivalent: "")
        let slots = NSMenu()
        let current = slot()
        for a in LockScreen.downloaded() {
            let i = item(a.name, #selector(pickSlot(_:)))
            i.representedObject = a.id
            i.state = a.id == current?.id ? .on : .off
            slots.addItem(i)
        }
        if slots.items.isEmpty { slots.addItem(NSMenuItem(title: "No Aerials downloaded — get one in Wallpaper settings", action: nil, keyEquivalent: "")) }
        slotItem.submenu = slots
        menu.addItem(slotItem)
        menu.addItem(item("Open Wallpaper Settings…", #selector(openSettings)))
        let restore = item("Restore Apple's Lock Screen", #selector(restoreApple))
        restore.isEnabled = !LockScreen.swappedIDs().isEmpty && !busy
        menu.addItem(restore)
        menu.addItem(.separator())

        let login = item("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit LoopPaper", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func libraryClips() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: AppPaths.library, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "mov" }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// The Aerial we write into: the user's pick, else the one selected in Settings, else the first downloaded.
    private func slot() -> Aerial? {
        let all = LockScreen.downloaded()
        if let id = Prefs.slotID, let a = all.first(where: { $0.id == id }) { return a }
        return LockScreen.currentlySelected() ?? all.first
    }

    // MARK: Actions

    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .mpeg4Movie, .quickTimeMovie, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Pick a GIF or video for your background"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        convert(url)
    }

    private func convert(_ input: URL) {
        let safe = input.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let stamp = Int(Date().timeIntervalSince1970)
        let out = AppPaths.library.appendingPathComponent("\(safe) \(stamp).mov")
        let thumb = out.deletingPathExtension().appendingPathExtension("png")
        busy = true
        setTitle(" 0%")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var lastShown = -1
                try Converter().convert(input: input, output: out, thumbnail: thumb) { p in
                    let pct = Int(p * 100)
                    if pct != lastShown {
                        lastShown = pct
                        DispatchQueue.main.async { self.setTitle(" \(pct)%") }
                    }
                }
                DispatchQueue.main.async { self.use(out) }
            } catch {
                try? FileManager.default.removeItem(at: out)
                DispatchQueue.main.async {
                    self.busy = false
                    self.setTitle("")
                    self.alert("That file didn't work", error.localizedDescription)
                }
            }
        }
    }

    /// Plays a converted clip on the desktop and, if on, puts it on the lock screen.
    private func use(_ clip: URL) {
        Prefs.current = clip.path
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: clip.path)
        desktop.play(clip)
        updatePlayback()
        guard Prefs.lockScreen else { busy = false; setTitle(""); return }
        guard let slot = slot() else {
            busy = false
            setTitle("")
            alert("Desktop is set, lock screen isn't",
                  "The lock screen needs one of Apple's moving Aerial wallpapers downloaded first. Open Wallpaper settings, click any Aerial (the moving landscapes) so it downloads, then pick your clip again.")
            return
        }
        Prefs.slotID = slot.id
        setTitle(" lock screen…")
        DispatchQueue.global(qos: .userInitiated).async {
            let thumb = clip.deletingPathExtension().appendingPathExtension("png")
            let result = Result { try LockScreen.apply(slot: slot, video: clip, thumbnail: thumb) }
            DispatchQueue.main.async {
                self.busy = false
                self.setTitle("")
                switch result {
                case .failure(let e):
                    self.alert("Lock screen couldn't be changed", e.localizedDescription)
                case .success:
                    if LockScreen.currentlySelected()?.id != slot.id || !Prefs.toldAboutSettings {
                        Prefs.toldAboutSettings = true
                        self.alert("One last step for the lock screen",
                                   "In Wallpaper settings, choose the Aerial called “\(slot.name)”. It now holds your clip (its thumbnail shows your clip). You only need to do this once; after that, picking a new clip here updates the lock screen by itself.\n\nLock your Mac (Control-Command-Q) to see it.",
                                   openSettings: true)
                    }
                }
            }
        }
    }

    @objc private func pickRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        busy = true
        use(url)
    }

    @objc private func pickSlot(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.slotID = id
        if Prefs.lockScreen, let path = Prefs.current {
            busy = true
            Prefs.toldAboutSettings = false
            use(URL(fileURLWithPath: path))
        }
    }

    @objc private func togglePause() { Prefs.userPaused.toggle(); updatePlayback() }
    @objc private func toggleBattery() { Prefs.pauseOnBattery.toggle(); updatePlayback() }
    @objc private func toggleLock() { Prefs.lockScreen.toggle() }

    @objc private func stopDesktop() {
        desktop.stop()
        Prefs.current = nil
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }

    @objc private func restoreApple() {
        busy = true
        setTitle(" restoring…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LockScreen.restore() }
            DispatchQueue.main.async {
                self.busy = false
                self.setTitle("")
                if case .failure(let e) = result { self.alert("Couldn't restore", e.localizedDescription) }
                else { self.alert("Restored", "Apple's original Aerial wallpaper is back.") }
            }
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change Open at Login", error.localizedDescription)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: UI helpers

    private func setTitle(_ s: String) { statusItem.button?.title = s }

    private func alert(_ title: String, _ text: String, openSettings: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if openSettings {
            a.addButton(withTitle: "Open Wallpaper Settings")
            a.addButton(withTitle: "Later")
            if a.runModal() == .alertFirstButtonReturn { self.openSettings() }
        } else {
            a.runModal()
        }
    }
}
