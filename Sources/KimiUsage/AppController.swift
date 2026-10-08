import AppKit
import SwiftUI

final class UsagePanel: NSPanel {
    var allowsFreeDragging = false
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if allowsFreeDragging, event.type == .leftMouseDown {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

final class UsageHostingView: NSHostingView<UsageView> {
    var makeContextMenu: (() -> NSMenu)?

    override func menu(for event: NSEvent) -> NSMenu? { makeContextMenu?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeContextMenu?() else { super.rightMouseDown(with: event); return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = UsageStore()
    private let client = QuotaClient()
    private let locator = KimiWindowLocator()
    private let styleCache = WindowStyleReaderCache()
    private var panel: UsagePanel!
    private var locatorTimer: Timer?
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var layoutTask: Task<Void, Never>?
    private var settingsController: BandSettingsWindowController?
    private let settingsKey = "quotaBandSettings.v1"
    private var chromeInsets: WindowChromeInsets?
    private var layoutBundleURL: URL?
    private var layoutProcessID: pid_t?
    private var layoutDisplayScale: CGFloat?
    private var lastLayoutRead = Date.distantPast
    private var lastAttachmentFrame: CGRect?
    private var sessionActive = true
    private var corner = AttachmentCorner(rawValue: UserDefaults.standard.string(forKey: "attachmentCorner") ?? "") ?? .bottomRight

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store.corner = corner
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let settings = try? JSONDecoder().decode(QuotaBandSettings.self, from: data),
           settings.validationMessage() == nil {
            store.bandSettings = settings
        }
        let automaticallyLaunched = CommandLine.arguments.contains("--follow-launch")
        createPanel()
        if corner == .free { restoreFreePosition() }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(self, selector: #selector(updateAttachment), name: name, object: nil)
        }
        center.addObserver(self, selector: #selector(kimiTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionResigned),
                           name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionBecameActive),
                           name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(wokeUp), name: NSWorkspace.didWakeNotification, object: nil)

        if automaticallyLaunched, !store.bandSettings.followsKimi || !isKimiRunning {
            NSApp.terminate(nil)
            return
        }

        updateLocatorTimer()
        refreshTimer = Timer(timeInterval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        refreshTimer?.tolerance = 5
        RunLoop.main.add(refreshTimer!, forMode: .common)
        updateAttachment()
        refresh()
        _ = applyFollowSetting(store.bandSettings.followsKimi)
        if !automaticallyLaunched { editBands() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        editBands()
        return false
    }

    private var isKimiRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: KimiWindowLocator.bundleID)
            .contains { !$0.isTerminated }
    }

    @objc private func kimiTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == KimiWindowLocator.bundleID,
              store.bandSettings.followsKimi, !isKimiRunning else { return }
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsController?.window,
              store.bandSettings.followsKimi, !isKimiRunning else { return }
        NSApp.terminate(nil)
    }

    private func applyFollowSetting(_ enabled: Bool) -> Bool {
        do {
            try FollowKimiService.setEnabled(enabled)
            return true
        } catch {
            let alert = NSAlert()
            alert.messageText = "未能更新自动跟随"
            alert.informativeText = "请确认 Kimi Usage.app 已放入「应用程序」，并在「系统设置 → 通用 → 登录项」中允许其后台活动。你也可以关闭自动跟随，继续手动运行。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        locatorTimer?.invalidate()
        refreshTimer?.invalidate()
        refreshTask?.cancel()
        layoutTask?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func createPanel() {
        panel = UsagePanel(contentRect: CGRect(origin: .zero, size: WindowGeometry.panelSize),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let content = UsageHostingView(rootView: UsageView(store: store))
        content.makeContextMenu = { [weak self] in self?.contextMenu() ?? NSMenu() }
        panel.contentView = content
        panel.delegate = self
        configurePlacement()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.isReleasedWhenClosed = false
    }

    @objc private func updateAttachment() {
        guard sessionActive else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        if corner == .free {
            if !panel.isVisible {
                panel.orderFrontRegardless()
                refreshIfStale()
            }
            return
        }
        guard let target = locator.locate() else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        updateLayout(for: target)
        let frame: CGRect?
        if let chromeInsets {
            frame = WindowGeometry.attachmentFrame(window: target.frame,
                visibleScreen: target.screen.visibleFrame, corner: corner, chrome: chromeInsets)
        } else {
            // A failed style read keeps the retry entry away from both edges.
            let available = target.frame.intersection(target.screen.visibleFrame).insetBy(dx: 14, dy: 14)
            let size = WindowGeometry.panelSize
            let left = corner == .topLeft || corner == .bottomLeft
            frame = available.width >= size.width && available.height >= size.height
                ? CGRect(x: left ? available.minX : available.maxX - size.width,
                         y: available.midY - size.height / 2, width: size.width, height: size.height) : nil
        }
        guard let frame else {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        // AppKit may round the origin; compare requests to avoid moving the same frame repeatedly.
        if lastAttachmentFrame != frame {
            panel.setFrameOrigin(frame.origin)
            lastAttachmentFrame = frame
        }
        let wasVisible = panel.isVisible
        let targetIsActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID
        let level = targetIsActive ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1) : .normal
        let levelChanged = panel.level != level
        if levelChanged { panel.level = level }
        if targetIsActive {
            if !wasVisible { panel.orderFrontRegardless() }
        } else {
            let ownIndex = target.orderedWindowIDs.firstIndex(of: CGWindowID(panel.windowNumber))
            let targetIndex = target.orderedWindowIDs.firstIndex(of: target.windowID)
            if levelChanged || ownIndex == nil || targetIndex == nil || ownIndex! + 1 != targetIndex! {
                panel.order(.above, relativeTo: Int(target.windowID))
            }
        }
        if !wasVisible { refreshIfStale() }
    }

    private func refreshIfStale() {
        if store.snapshot.map({ Date().timeIntervalSince($0.updatedAt) >= 60 }) ?? true { refresh() }
    }

    private func updateLocatorTimer() {
        guard sessionActive, corner != .free else {
            locatorTimer?.invalidate()
            locatorTimer = nil
            return
        }
        guard locatorTimer == nil else { return }
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(updateAttachment), userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        locatorTimer = timer
    }

    private func configurePlacement() {
        lastAttachmentFrame = nil
        let free = corner == .free
        panel.isFloatingPanel = free
        panel.level = free ? .floating : .normal
        panel.isMovable = free
        panel.isMovableByWindowBackground = free
        panel.allowsFreeDragging = free
    }

    private func restoreFreePosition() {
        let size = WindowGeometry.panelSize
        let saved = UserDefaults.standard.array(forKey: "freePanelOrigin") as? [Double]
        let proposed: CGPoint
        if let saved, saved.count == 2, saved.allSatisfy(\.isFinite) {
            proposed = CGPoint(x: saved[0], y: saved[1])
        } else if panel.isVisible {
            proposed = panel.frame.origin
        } else if let screen = NSScreen.main {
            proposed = CGPoint(x: screen.visibleFrame.maxX - size.width - 14,
                               y: screen.visibleFrame.minY + 14)
        } else { return }
        let proposedFrame = CGRect(origin: proposed, size: size)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(proposedFrame) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: min(max(proposed.x, visible.minX), visible.maxX - size.width),
                                     y: min(max(proposed.y, visible.minY), visible.maxY - size.height)))
        saveFreePosition()
    }

    func windowDidMove(_ notification: Notification) {
        guard corner == .free, let window = notification.object as? NSWindow, window === panel else { return }
        saveFreePosition()
    }

    private func saveFreePosition() {
        UserDefaults.standard.set([Double(panel.frame.minX), Double(panel.frame.minY)], forKey: "freePanelOrigin")
    }

    private func updateLayout(for target: KimiWindowLocator.Target) {
        let displayScale = target.screen.backingScaleFactor
        if layoutBundleURL != target.bundleURL || layoutProcessID != target.processID || layoutDisplayScale != displayScale {
            chromeInsets = nil
            layoutBundleURL = target.bundleURL
            layoutProcessID = target.processID
            layoutDisplayScale = displayScale
            lastLayoutRead = .distantPast
        }
        guard layoutTask == nil, Date().timeIntervalSince(lastLayoutRead) >= 30 else { return }
        lastLayoutRead = Date()
        let bundleURL = target.bundleURL
        layoutTask = Task { [weak self] in
            let measurement = await self?.styleCache.read(bundleURL: bundleURL, displayScale: displayScale)
            guard let self, !Task.isCancelled else { return }
            self.layoutTask = nil
            guard let measurement else { return }
            guard self.layoutBundleURL == bundleURL, self.layoutDisplayScale == displayScale else { return }
            if let insets = measurement.insets {
                self.chromeInsets = insets
                if self.store.layoutNotice != nil { self.store.layoutNotice = nil }
                if self.store.targetStatus != nil { self.store.targetStatus = nil }
            } else {
                if self.store.layoutNotice != measurement.status { self.store.layoutNotice = measurement.status }
                if self.store.targetStatus != "布局待更新" { self.store.targetStatus = "布局待更新" }
            }
            self.updateAttachment()
        }
    }

    @objc private func refresh() {
        guard !store.isRefreshing else { return }
        store.isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.store.isRefreshing = false }
            do {
                let result = try await self.client.fetch()
                guard !Task.isCancelled else { return }
                self.store.snapshot = result
                self.store.errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.store.errorMessage = error.localizedDescription
            }
        }
    }

    private func changeCorner(_ value: AttachmentCorner) {
        corner = value
        store.corner = value
        UserDefaults.standard.set(value.rawValue, forKey: "attachmentCorner")
        configurePlacement()
        updateLocatorTimer()
        if value == .free { restoreFreePosition() }
        updateAttachment()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refresh), keyEquivalent: "")
        refreshItem.target = self
        refreshItem.isEnabled = !store.isRefreshing
        menu.addItem(refreshItem)
        let positionItem = NSMenuItem(title: "附着位置", action: nil, keyEquivalent: "")
        let positions = NSMenu()
        positions.autoenablesItems = false
        for option in AttachmentCorner.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == corner ? .on : .off
            positions.addItem(item)
        }
        positionItem.submenu = positions
        menu.addItem(positionItem)
        let settingsItem = NSMenuItem(title: "显示设置…", action: #selector(editBands), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        if let notice = store.layoutNotice {
            menu.addItem(.separator())
            let statusItem = NSMenuItem(title: notice, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
            let retry = NSMenuItem(title: "重新读取界面样式", action: #selector(retryLayout), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        if let error = store.errorMessage {
            menu.addItem(.separator())
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Kimi 额度", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func selectCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let option = AttachmentCorner(rawValue: raw) else { return }
        changeCorner(option)
    }

    @objc private func editBands() {
        if settingsController?.window?.isVisible != true {
            settingsController = BandSettingsWindowController(settings: store.bandSettings) { [weak self] settings in
                guard let self, settings.validationMessage() == nil,
                      let data = try? JSONEncoder().encode(settings),
                      self.applyFollowSetting(settings.followsKimi) else { return false }
                UserDefaults.standard.set(data, forKey: self.settingsKey)
                self.store.bandSettings = settings
                return true
            }
            settingsController?.window?.delegate = self
        }
        settingsController?.present(near: panel)
    }

    @objc private func retryLayout() {
        lastLayoutRead = .distantPast
        updateAttachment()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func sessionResigned() {
        sessionActive = false
        updateLocatorTimer()
        panel.orderOut(nil)
    }
    @objc private func sessionBecameActive() {
        sessionActive = true
        updateLocatorTimer()
        updateAttachment()
        refresh()
    }
    @objc private func wokeUp() { updateLocatorTimer(); updateAttachment(); refresh() }
}
