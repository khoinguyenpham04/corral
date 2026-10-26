import AppKit
import CorralUI
import SwiftUI

/// A borderless, non-activating panel under the menu bar item. It's as tall as the screen and
/// transparent below the panel, so the SwiftUI content can grow and animate without the window
/// resizing; clicks on the transparent part fall through to whatever is underneath.
final class FloatingPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PanelController {
    private let panel = FloatingPanel()
    private let model: PanelModel
    private var monitors: [Any] = []
    private(set) var isVisible = false
    var onVisibilityChange: (Bool) -> Void = { _ in }
    var onShortcut: (String) -> Void = { _ in }

    init(model: PanelModel) {
        self.model = model
        let host = NSHostingView(rootView: PanelHost(model: model, dismiss: {}))
        host.sizingOptions = []
        panel.contentView = host
        host.rootView = PanelHost(model: model) { [weak self] in self?.hide() }
    }

    func toggle(below button: NSStatusBarButton?) {
        isVisible ? hide() : show(below: button)
    }

    /// Shows the panel under `button`, or at the top right of the screen with the mouse when the
    /// menu bar had no room for the button.
    func show(below button: NSStatusBarButton?) {
        let anchor = button.flatMap { button -> NSRect? in
            guard let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }
        let mouse = NSEvent.mouseLocation
        let screen = button?.window?.screen
            ?? NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let pad = PanelHost.shadowPadding
        let width = Metrics.panelWidth + pad * 2
        let height = visible.height + pad - 6
        var x = (anchor?.midX ?? visible.maxX - Metrics.panelWidth / 2 - 10) - width / 2
        x = min(max(x, visible.minX - pad + 6), visible.maxX - width + pad - 6)
        let top = visible.maxY + pad - 6
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: false)

        model.maxListHeight = max(240, visible.height - 300)
        // Tell the store first, so the latest sample is in place before the panel draws.
        isVisible = true
        onVisibilityChange(true)
        model.openCount += 1
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
    }

    /// Fades out quickly, the way menus close. Opening it again mid-fade cancels the fade.
    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeMonitors()
        onVisibilityChange(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps (and on the transparent part of this window) close the panel.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            let command = event.modifierFlags.contains(.command)
            let key = event.charactersIgnoringModifiers ?? ""
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isVisible else { return false }
                if keyCode == 53 {
                    self.hide()
                    return true
                }
                if command, [",", "r", "q", "h", "z", "1", "2"].contains(key) {
                    self.onShortcut(key)
                    return true
                }
                return false
            }
            return handled ? nil : event
        }) {
            monitors.append(monitor)
        }
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
    }
}
