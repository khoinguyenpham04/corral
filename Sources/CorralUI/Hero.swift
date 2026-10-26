import CorralCore
import SwiftUI

/// The README's hero image: the panel open under Corral's menu bar icon, on an ink and ember
/// desktop. CorralPreview renders it to docs/hero.png.
public struct HeroScene: View {
    public static let size = CGSize(width: 980, height: 1010)

    let model: PanelModel

    public init(model: PanelModel) {
        self.model = model
    }

    public var body: some View {
        let palette = Palette.dark
        ZStack(alignment: .topLeading) {
            Wallpaper(palette: palette)
            MenuBarStrip()
            PanelView(model: model)
                .fixedSize()
                .shadow(color: .black.opacity(0.55), radius: 40, y: 22)
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .padding(.top, MenuBarStrip.height + 7)
                .padding(.leading, MenuBarStrip.glyphCenter - Metrics.panelWidth / 2)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

/// Ink with ember, mango and lavender light, and the Connect fan of lines running behind.
private struct Wallpaper: View {
    let palette: Palette

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x0D0D0D), Color(hex: 0x161210)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [palette.ember.opacity(0.75), palette.ember.opacity(0.18), .clear], center: UnitPoint(x: 0.12, y: 1.0), startRadius: 10, endRadius: 760)
            RadialGradient(colors: [palette.mango.opacity(0.32), .clear], center: UnitPoint(x: 0.42, y: 1.08), startRadius: 10, endRadius: 520)
            RadialGradient(colors: [palette.lavender.opacity(0.38), .clear], center: UnitPoint(x: 1.0, y: 0.92), startRadius: 10, endRadius: 620)
            WaveField(line: palette.ember, accents: [palette.mango, palette.pink, palette.lavender], drift: 1, strength: 0.55)
                .frame(height: HeroScene.size.height * 0.9)
                .offset(y: HeroScene.size.height * 0.18)
                .blendMode(.screen)
        }
    }
}

/// A macOS menu bar with Corral's icon highlighted, as when the panel is open.
private struct MenuBarStrip: View {
    static let height: CGFloat = 30
    /// Where Corral's icon sits, so the panel can hang under it.
    static let glyphCenter: CGFloat = HeroScene.size.width - 14 - 368 + 15

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 20) {
                Image(systemName: "apple.logo").font(.system(size: 15, weight: .medium))
                Text("Finder").font(.system(size: 13.5, weight: .bold))
                ForEach(["File", "Edit", "View", "Go", "Window"], id: \.self) { Text($0) }
            }
            Spacer()
            HStack(spacing: 10) {
                CorralGlyph()
                    .frame(width: 18, height: 18)
                    .frame(width: 30, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.22)))
                Image(systemName: "cloud").frame(width: 24)
                Image(systemName: "chart.bar.xaxis").frame(width: 24)
                Image(systemName: "speaker.wave.2").frame(width: 24)
                Image(systemName: "wifi").frame(width: 26)
                Image(systemName: "battery.75percent").frame(width: 34)
                Image(systemName: "switch.2").frame(width: 26)
                Text("Fri Oct 16  9:41").frame(width: 110, alignment: .trailing)
            }
        }
        .font(.system(size: 13.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.94))
        .padding(.horizontal, 14)
        .frame(width: HeroScene.size.width, height: Self.height)
        .background(.black.opacity(0.28))
    }
}

/// The menu bar icon: a ring of fence posts around a sparkle.
struct CorralGlyph: View {
    var color: Color = .white

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let inset = side * 2.2 / 18
            let circumference = Double.pi * (side - inset * 2)
            let dash = circumference / 10 * 0.58
            ZStack {
                Circle()
                    .inset(by: inset)
                    .stroke(color, style: StrokeStyle(lineWidth: side * 1.5 / 18, lineCap: .round, dash: [dash, circumference / 10 - dash]))
                Sparkle().fill(color).padding(side * 5.4 / 18)
            }
        }
    }
}

/// The disk image's window: drag Corral, on the left, onto Applications, on the right. Finder
/// draws the icons and their labels over this at `iconCenters`, in a 660 × 420 window.
public struct InstallerBackground: View {
    /// The picture. Its top 660 × 420 is what a Finder window shows on macOS 26; the last 20
    /// points carry on the background for windows with a shorter title bar.
    public static let size = CGSize(width: 660, height: 440)
    public static let visibleHeight: CGFloat = 420
    public static let iconCenters = (app: CGPoint(x: 180, y: 212), applications: CGPoint(x: 480, y: 212))

    public init() {}

    public var body: some View {
        let palette = Palette.dark
        ZStack {
            LinearGradient(colors: [Color(hex: 0x111111), Color(hex: 0x17120F)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [palette.ember.opacity(0.55), palette.ember.opacity(0.1), .clear], center: UnitPoint(x: 0.0, y: 1.05), startRadius: 4, endRadius: 420)
            RadialGradient(colors: [palette.lavender.opacity(0.28), .clear], center: UnitPoint(x: 1.0, y: 0.0), startRadius: 4, endRadius: 360)
            WaveField(line: palette.ember, accents: [], drift: 1, strength: 0.32)
                .frame(height: Self.visibleHeight * 0.95)
                .offset(y: Self.visibleHeight * 0.16 - (Self.size.height - Self.visibleHeight) / 2)
                .blendMode(.screen)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Sparkle().fill(palette.ember).frame(width: 14, height: 14)
                    Text("Corral").font(Typeface.wordmark(26)).foregroundStyle(palette.text)
                }
                Text("Drag Corral to Applications").smallCaps(palette.text2)
            }
            .position(x: Self.size.width / 2, y: 62)

            // The poster's "— — ————" rule, ending in an arrowhead, from one icon to the other.
            Arrow()
                .stroke(palette.ember, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 150, height: 14)
                .position(x: Self.size.width / 2, y: Self.iconCenters.app.y - 4)

            Text("If macOS stops it the first time: System Settings → Privacy & Security → Open Anyway")
                .font(.system(size: 11))
                .foregroundStyle(palette.text2)
                .position(x: Self.size.width / 2, y: Self.visibleHeight - 28)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }
}

private struct Arrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.midY
        var x = rect.minX
        for length in [12.0, 12.0] {
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + length, y: y))
            x += length + 8
        }
        path.move(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        path.move(to: CGPoint(x: rect.maxX - 7, y: y - 6))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX - 7, y: y + 6))
        return path
    }
}
