import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: DeviceStore
    private var cancellables = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?

    init(store: DeviceStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "air.conditioner.horizontal", accessibilityDescription: "Breeze")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = ProcessInfo.processInfo.environment["BREEZE_PREVIEW"] != nil ? .applicationDefined : .transient
        popover.animates = true
        // Breeze follows the system appearance (Travertine by day, Basalt by night); previews can pin one.
        if let forced = ProcessInfo.processInfo.environment["BREEZE_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: forced == "light" ? .aqua : .darkAqua)
        }
        popover.delegate = self
        let host = NSHostingController(rootView: RootView().environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        store.$menuBarTitle
            .receive(on: RunLoop.main)
            .sink { [weak self] title in
                self?.statusItem.button?.title = title
            }
            .store(in: &cancellables)

        store.$menuBarAlert
            .receive(on: RunLoop.main)
            .sink { [weak self] alert in
                self?.statusItem.button?.contentTintColor = alert ? .systemOrange : nil
            }
            .store(in: &cancellables)

        store.openSettingsRequested = { [weak self] in self?.showSettings() }
        store.showPopoverRequested = { [weak self] in
            guard let self, !self.popover.isShown else { return }
            self.togglePopover()
        }
        store.quitRequested = { NSApp.terminate(nil) }

        if ProcessInfo.processInfo.environment["BREEZE_PREVIEW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.togglePopover()
                let delay = Double(ProcessInfo.processInfo.environment["BREEZE_SNAPSHOT_DELAY"] ?? "") ?? 1.2
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if let window = self?.popover.contentViewController?.view.window {
                        print("BREEZE_POPOVER_WINDOW=\(window.windowNumber)")
                        if let path = ProcessInfo.processInfo.environment["BREEZE_SNAPSHOT"] {
                            if ProcessInfo.processInfo.environment["BREEZE_SNAPSHOT_SCALE"] == "2", let store = self?.store {
                                Self.render(store: store, to: path)
                            } else {
                                Self.snapshot(window: window, to: path)
                            }
                        }
                        fflush(stdout)
                        if let settingsPath = ProcessInfo.processInfo.environment["BREEZE_SNAPSHOT_SETTINGS"] {
                            self?.showSettings()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                                if let w = self?.settingsWindow { Self.snapshot(window: w, to: settingsPath) }
                                fflush(stdout)
                            }
                        }
                    }
                }
            }
        }
    }

    @objc private func handleClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            store.popoverWillShow()
            // A popover from the status bar inherits the menu bar's appearance; follow the system setting instead.
            popover.appearance = NSApp.effectiveAppearance
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in store.popoverDidHide() }
    }

    // At willShow the content view still sits in a staging window; the popover frame exists a run-loop turn later.
    nonisolated func popoverWillShow(_ notification: Notification) {
        MainActor.assumeIsolated { DispatchQueue.main.async { [weak self] in self?.paintPopoverFrame() } }
    }

    nonisolated func popoverDidShow(_ notification: Notification) {
        MainActor.assumeIsolated { paintPopoverFrame() }
    }

    /// NSPopover draws its frame, arrow included, in a system material that has nothing to do with the panel.
    /// A view in the panel's ground colour, slipped under the content inside the frame's material view, is clipped
    /// to the popover's shape by the frame's own mask, so the arrow becomes part of the panel.
    private func paintPopoverFrame() {
        // The popover window hands back our own view as its content view; the frame that draws the arrow is its topmost ancestor.
        guard let content = popover.contentViewController?.view, content.window != nil else { return }
        var frame: NSView = content
        while let parent = frame.superview { frame = parent }
        guard frame !== content else { return }
        let appearance = popover.appearance ?? NSApp.effectiveAppearance
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ground = NSColor(hex: isDark ? "#130f0a" : "#e7ded4").cgColor
        let id = NSUserInterfaceItemIdentifier("breeze-ground")
        func effectView(in view: NSView) -> NSVisualEffectView? {
            if let e = view as? NSVisualEffectView { return e }
            for sub in view.subviews { if let e = effectView(in: sub) { return e } }
            return nil
        }
        let host: NSView = effectView(in: frame) ?? frame
        if let existing = host.subviews.first(where: { $0.identifier == id }) {
            existing.layer?.backgroundColor = ground
        } else {
            let view = NSView(frame: host.bounds)
            view.identifier = id
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            view.layer?.backgroundColor = ground
            host.addSubview(view, positioned: .below, relativeTo: host.subviews.first)
        }
        frame.wantsLayer = true
        frame.layer?.backgroundColor = ground
        outlinePopover(in: host, content: content, isDark: isDark)
    }

    /// NSPopover's own hairline sits under the ground we paint, so the panel draws its own: one point inside the
    /// popover's shape, arrow included, so the line climbs over the arrow instead of cutting across its base.
    private func outlinePopover(in host: NSView, content: NSView, isDark: Bool) {
        let name = "breeze-edge"
        let layer = (host.layer?.sublayers?.first { $0.name == name } as? CAShapeLayer) ?? {
            let l = CAShapeLayer(); l.name = name; l.fillColor = nil; l.lineWidth = 1
            host.wantsLayer = true; host.layer?.addSublayer(l); return l
        }()
        layer.strokeColor = NSColor(hex: isDark ? "#fff0dc38" : "#4a3a2824").cgColor
        let r = content.frame.insetBy(dx: 0.5, dy: 0.5), radius: CGFloat = 10.5
        var arrowX: CGFloat? = nil
        if let button = statusItem.button, let bw = button.window, let pw = content.window {
            let onScreen = bw.convertToScreen(button.convert(button.bounds, to: nil))
            let x = onScreen.midX - pw.frame.minX
            if x > r.minX + radius + 14 && x < r.maxX - radius - 14 { arrowX = x }
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: r.minX + radius, y: r.maxY))
        if let ax = arrowX {
            p.addLine(to: CGPoint(x: ax - 12.5, y: r.maxY))
            p.addLine(to: CGPoint(x: ax, y: r.maxY + 11.5))
            p.addLine(to: CGPoint(x: ax + 12.5, y: r.maxY))
        }
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX, y: r.maxY - radius), radius: radius)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX - radius, y: r.minY), radius: radius)
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX, y: r.minY + radius), radius: radius)
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX + radius, y: r.maxY), radius: radius)
        p.closeSubpath()
        layer.frame = host.bounds
        layer.path = p
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Breeze", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Capture one of our own windows to a PNG (no screen-recording permission needed for own windows).
    /// Renders the panel offscreen at 2x, without the popover chrome, for documentation and the website.
    static func render(store: DeviceStore, to path: String) {
        let dark = ProcessInfo.processInfo.environment["BREEZE_APPEARANCE"] != "light"
        let content = RootView()
            .environmentObject(store)
            .environment(\.colorScheme, dark ? .dark : .light)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        var image: NSImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance { image = renderer.nsImage }
        guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { print("BREEZE_SNAPSHOT_FAILED"); return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("BREEZE_SNAPSHOT_WRITTEN=\(path)")
    }

    static func snapshot(window: NSWindow, to path: String) {
        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .bestResolution]) else {
            print("BREEZE_SNAPSHOT_FAILED"); return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("BREEZE_SNAPSHOT_WRITTEN=\(path)")
        }
    }

    @objc private func refreshNow() { store.refreshNow() }
    @objc private func openSettings() { showSettings() }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 780),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Breeze Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(store))
            window.center()
            settingsWindow = window
        }
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
