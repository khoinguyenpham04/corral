import AppKit
import CorralCore
import CorralUI

/// The menu bar item: a corral (a ring of fence posts) around a sparkle. It turns mango or coral
/// when memory pressure rises and can show worktree memory or the idle-agent count beside it.
@MainActor
final class StatusItemController: NSObject {
    let item: NSStatusItem
    private let onClick: () -> Void
    private let menu: () -> NSMenu
    private var lastKey = ""

    init(onClick: @escaping () -> Void, menu: @escaping () -> NSMenu) {
        // New items go in at the far left, which on a full menu bar means behind the notch.
        // The first time, ask for the right end of the app items instead (offset from the
        // screen's right edge); after that macOS remembers wherever the user ⌘-drags it.
        let positionKey = "NSStatusItem Preferred Position corral"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(0, forKey: positionKey)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "corral"
        self.onClick = onClick
        self.menu = menu
        super.init()
        if let button = item.button {
            button.image = Self.glyph(pressure: .normal)
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Corral"
        }
    }

    var button: NSStatusBarButton? { item.button }

    /// False when macOS has no room for the item: it's off screen, or behind the notch.
    var isOnScreen: Bool {
        guard let window = item.button?.window, let screen = window.screen, window.occlusionState.contains(.visible) else { return false }
        if let rightOfNotch = screen.auxiliaryTopRightArea, window.frame.minX < rightOfNotch.minX { return false }
        return window.frame.maxX <= screen.frame.maxX && window.frame.width > 0
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            item.menu = menu()
            sender.performClick(nil)
            item.menu = nil
        } else {
            onClick()
        }
    }

    func update(snapshot: Snapshot, idleAgents: Int, style: MenuBarStyle) {
        let pressure = snapshot.system.pressure
        var title = ""
        switch style {
        case .icon: break
        case .memory: title = Format.bytes(snapshot.trackedMemory)
        case .idle: title = idleAgents > 0 ? "\(idleAgents)" : ""
        }
        let key = "\(pressure.rawValue)|\(title)"
        guard key != lastKey, let button = item.button else { return }
        lastKey = key
        button.image = Self.glyph(pressure: pressure)
        button.attributedTitle = NSAttributedString(
            string: title.isEmpty ? "" : " " + title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .baselineOffset: 0.5]
        )
        var tip = "Corral · \(Format.bytes(snapshot.trackedMemory)) in worktrees"
        if idleAgents > 0 { tip += " · \(idleAgents) idle agent\(idleAgents == 1 ? "" : "s")" }
        if pressure != .normal { tip += " · \(pressure.label) memory pressure" }
        button.toolTip = tip
    }

    /// Drawn in code so it stays crisp at every scale. A template image when all is well.
    static func glyph(pressure: SystemMemory.Pressure) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let tint: NSColor? = switch pressure {
        case .normal: nil
        case .warning: NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 1)
        case .critical: NSColor(srgbRed: 1, green: 0.41, blue: 0.4, alpha: 1)
        }
        let image = NSImage(size: size, flipped: false) { rect in
            (tint ?? .black).set()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.2, dy: 2.2))
            ring.lineWidth = 1.5
            let circumference = Double.pi * (rect.width - 4.4)
            let posts = 10.0
            let dash = circumference / posts * 0.58
            ring.setLineDash([dash, circumference / posts - dash], count: 2, phase: 0)
            ring.lineCapStyle = .round
            ring.stroke()
            sparkle(in: rect.insetBy(dx: 5.4, dy: 5.4)).fill()
            return true
        }
        image.isTemplate = tint == nil
        return image
    }

    static func sparkle(in rect: NSRect, waist: CGFloat = 0.16) -> NSBezierPath {
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let w = rect.width / 2
        let h = rect.height / 2
        let path = NSBezierPath()
        func quad(to end: NSPoint, control: NSPoint) {
            let start = path.currentPoint
            let c1 = NSPoint(x: start.x + 2 / 3 * (control.x - start.x), y: start.y + 2 / 3 * (control.y - start.y))
            let c2 = NSPoint(x: end.x + 2 / 3 * (control.x - end.x), y: end.y + 2 / 3 * (control.y - end.y))
            path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
        }
        path.move(to: NSPoint(x: c.x, y: c.y + h))
        quad(to: NSPoint(x: c.x + w, y: c.y), control: NSPoint(x: c.x + w * waist, y: c.y + h * waist))
        quad(to: NSPoint(x: c.x, y: c.y - h), control: NSPoint(x: c.x + w * waist, y: c.y - h * waist))
        quad(to: NSPoint(x: c.x - w, y: c.y), control: NSPoint(x: c.x - w * waist, y: c.y - h * waist))
        quad(to: NSPoint(x: c.x, y: c.y + h), control: NSPoint(x: c.x - w * waist, y: c.y + h * waist))
        path.close()
        return path
    }
}
