// Renders the panel to PNGs (build/previews) so the design can be reviewed without running the app.
import AppKit
import CorralCore
import CorralUI
import SwiftUI

let directory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/previews")
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let now = Date()
let defaults = UserDefaults(suiteName: "io.github.khoinguyenpham04.corral.preview") ?? .standard
defaults.removePersistentDomain(forName: "io.github.khoinguyenpham04.corral.preview")

@MainActor
func render(_ name: String, scheme: ColorScheme, configure: (PanelModel) -> Void) {
    let model = PanelModel(snapshot: PreviewData.snapshot(now: now), hibernated: [], settings: CorralSettings(defaults: defaults), now: now)
    model.scrolls = false
    model.disk = PreviewData.disk(now: now)
    model.volume = VolumeSpace(available: 61 << 30, total: 994 << 30, device: 1)
    configure(model)
    let backdrop = scheme == .dark ? Color(white: 0.09) : Color(white: 0.86)
    let view = PanelView(model: model)
        .shadow(color: .black.opacity(scheme == .dark ? 0.6 : 0.22), radius: 28, y: 14)
        .padding(36)
        .background(backdrop)
        .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage else {
        print("failed: \(name)")
        return
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    let url = directory.appendingPathComponent("\(name).png")
    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    print("\(url.path)  \(image.width)×\(image.height)")
}

/// The README's hero image: the panel under the menu bar, on a Corral desktop.
@MainActor
func renderHero() {
    let model = PanelModel(snapshot: PreviewData.hero(now: now), hibernated: [], settings: CorralSettings(defaults: defaults), now: now)
    model.scrolls = false
    model.expanded = [model.snapshot.checkouts.first { $0.name == "meadow" }!.id]
    let renderer = ImageRenderer(content: HeroScene(model: model))
    renderer.scale = 2
    guard let image = renderer.cgImage else {
        print("failed: hero")
        return
    }
    // JPEG: the wallpaper's gradients are ten times smaller than as PNG, and the text stays sharp at 2x.
    let url = directory.appendingPathComponent("hero.jpg")
    try? NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.88])?.write(to: url)
    print("\(url.path)  \(image.width)×\(image.height)")
}

/// The app icon at 256 px, for the README.
func renderSmallIcon() {
    let source = directory.appendingPathComponent("app-icon.png")
    guard let icon = NSImage(contentsOf: source),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(in: NSRect(x: 0, y: 0, width: 256, height: 256))
    NSGraphicsContext.restoreGraphicsState()
    let url = directory.appendingPathComponent("icon-256.png")
    try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    print("\(url.path)  256×256")
}

/// The disk image's background as background.png and background@2x.png, which dmgbuild joins
/// into one HiDPI TIFF with Apple's tiffutil. Opaque, since Finder draws it as the window.
@MainActor
func renderInstallerBackground() {
    for (scale, suffix) in [(1.0, ""), (2.0, "@2x")] {
        let renderer = ImageRenderer(content: InstallerBackground())
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { continue }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = InstallerBackground.size
        let url = directory.appendingPathComponent("installer-background\(suffix).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("\(url.path)  \(image.width)×\(image.height)")
    }

    // A mock of the finished window, with the app icon and a folder where Finder draws them.
    let icon = NSImage(contentsOf: directory.appendingPathComponent("app-icon.png"))
    let folder = NSWorkspace.shared.icon(forFile: "/Applications")
    let mock = ZStack(alignment: .topLeading) {
        InstallerBackground()
        ForEach(Array([(icon, "Corral", InstallerBackground.iconCenters.app), (folder, "Applications", InstallerBackground.iconCenters.applications)].enumerated()), id: \.offset) { _, item in
            VStack(spacing: 4) {
                if let image = item.0 { Image(nsImage: image).resizable().frame(width: 112, height: 112) }
                Text(item.1).font(.system(size: 13)).foregroundStyle(.white)
            }
            .position(x: item.2.x, y: item.2.y + 10)
        }
    }
    .frame(width: InstallerBackground.size.width, height: InstallerBackground.visibleHeight, alignment: .top)
    .clipped()
    let renderer = ImageRenderer(content: mock)
    renderer.scale = 2
    if let image = renderer.cgImage {
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("installer-mock.png"))
    }
}

MainActor.assumeIsolated {
    renderHero()
    renderInstallerBackground()
    renderSmallIcon()
    let meadow = { (model: PanelModel) in model.snapshot.checkouts.first { $0.name == "meadow" }!.id }
    render("panel-dark", scheme: .dark) { _ in }
    render("panel-open", scheme: .dark) { model in
        model.expanded = [meadow(model)]
    }
    render("panel-welcome", scheme: .dark) { model in
        model.showsWelcome = true
        model.opensAtLogin = true
        model.update = UpdateCheck.Release(version: "0.5.0")
    }
    render("panel-ledger", scheme: .dark) { model in
        model.expanded = ["shared", "hibernated"]
        model.hibernated = PreviewData.hibernated(now: now)
        model.toast = Toast(
            message: "Hibernated 3 agents · freed 1.7 GB", detail: "Onboarding email copy and 2 more",
            action: .wake([]), actionTitle: "Undo"
        )
    }
    render("panel-leaked-armed", scheme: .dark) { model in
        let leaked = model.leakedServers
        model.arm("leaked:" + leaked.map(\.id).sorted().joined(separator: ","))
    }
    render("panel-activity", scheme: .dark) { model in
        model.activity = PreviewData.activity(now: now)
        model.expanded = ["activity", "elsewhere"]
    }
    render("panel-light", scheme: .light) { model in
        model.expanded = [model.snapshot.checkouts.first { $0.name == "visual-edits" }!.id, meadow(model)]
        model.showsSmaller = true
        model.hibernated = PreviewData.hibernated(now: now)
        model.toast = Toast(message: "Stopped astro dev :4323 · freed 2.3 GB")
    }
    render("panel-disk", scheme: .dark) { model in
        model.tab = .disk
    }
    render("panel-disk-armed", scheme: .dark) { model in
        model.tab = .disk
        model.trashing = [model.disk!.worktrees[2].id]
        model.arm("trash-all:" + model.trashable.map(\.id).sorted().joined(separator: ","))
    }
    render("panel-disk-toast", scheme: .dark) { model in
        model.tab = .disk
        model.disk!.worktrees.removeAll { $0.canTrash }
        model.toast = Toast(
            message: "Moved 7 worktrees to the Trash", detail: "Empty the Trash to free 6.2 GB · branches stay",
            action: .putBack([]), actionTitle: "Undo"
        )
    }
    render("panel-disk-nudge", scheme: .dark) { model in
        model.volume = VolumeSpace(available: 18 << 30, total: 494 << 30, device: 1)
    }
    render("panel-disk-light", scheme: .light) { model in
        model.tab = .disk
        model.showsAllWorktrees = true
    }
    render("panel-disk-measuring", scheme: .dark) { model in
        model.tab = .disk
        var report = model.disk!
        for index in 5..<report.worktrees.count { report.worktrees[index].usage = nil }
        report.progress = DiskReport.Progress(done: 5, total: 11)
        model.disk = report
    }
    // More than fits on a line: the least important pieces drop out whole.
    render("panel-crowded", scheme: .dark) { model in
        var snapshot = model.snapshot
        let index = snapshot.checkouts.firstIndex { $0.name == "meadow" }!
        let base = snapshot.checkouts[index].groups.first { $0.bucket == .stacks }!
        for (offset, port) in [51730, 6006].enumerated() {
            var server = base
            server.id += "-\(offset)"
            server.title = "storybook :\(port)"
            server.ports = [port]
            snapshot.checkouts[index].groups.append(server)
        }
        var build = base
        build.id += "-build"
        build.bucket = .build
        build.title = "tsc --watch"
        build.ports = []
        snapshot.checkouts[index].groups.append(build)
        for group in snapshot.checkouts[index].groups.indices where snapshot.checkouts[index].groups[group].agent != nil {
            snapshot.checkouts[index].groups[group].agent?.state = .working
        }
        model.snapshot = snapshot
        model.expanded = [snapshot.checkouts[index].id]
    }
    render("panel-pressure", scheme: .dark) { model in
        model.snapshot.system.pressure = .warning
    }
    render("panel-read-only", scheme: .dark) { model in
        model.settings.readOnly = true
        model.expanded = [meadow(model)]
    }
}
