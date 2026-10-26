import SwiftUI

/// The four-point star from the Cloud Coffee posters: concave sides, a slightly full centre.
public struct Sparkle: Shape {
    public var waist: CGFloat

    public init(waist: CGFloat = 0.16) {
        self.waist = waist
    }

    public func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let w = rect.width / 2
        let h = rect.height / 2
        let k = waist
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y - h))
        path.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: CGPoint(x: c.x + w * k, y: c.y - h * k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + h), control: CGPoint(x: c.x + w * k, y: c.y + h * k))
        path.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y), control: CGPoint(x: c.x - w * k, y: c.y + h * k))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - h), control: CGPoint(x: c.x - w * k, y: c.y - h * k))
        path.closeSubpath()
        return path
    }
}

/// Fine lines gathered at the left and fanning out to the right with one shared wave, after the
/// Connect 2026 artwork, with a few coloured dashes riding on them. `drift` eases the fan open
/// when the panel appears.
struct WaveField: View {
    var line: Color
    var accents: [Color]
    var drift: Double
    var strength: Double = 1
    /// How far along the lines the coloured dashes start, as a fraction of the width.
    var dashesAt = 0.40

    var body: some View {
        Canvas { context, size in
            let count = 36
            let steps = 72
            var accentIndex = 0
            for index in 0..<count {
                let t = Double(index) / Double(count - 1)
                var points: [CGPoint] = []
                points.reserveCapacity(steps + 1)
                for step in 0...steps {
                    let u = Double(step) / Double(steps)
                    let spread = (0.10 + 0.95 * pow(u, 1.3)) * (0.82 + 0.18 * drift)
                    let wave = sin((u * 1.6 - 0.2 + drift * 0.12) * .pi) * size.height * 0.15
                    let y = size.height * (0.30 + (t - 0.5) * spread * 1.2) - wave
                    points.append(CGPoint(x: size.width * u, y: y))
                }
                var path = Path()
                path.addLines(points)
                let emphasis = 1 - min(1, abs(t - 0.45) / 0.55)
                context.stroke(path, with: .color(line.opacity((0.12 + 0.48 * emphasis) * strength)), lineWidth: 0.75)

                if index % 6 == 3, !accents.isEmpty {
                    // Left of the RAM figures, so the dashes never cross text.
                    let at = Int(Double(steps) * (dashesAt + 0.06 * Double(index % 4)))
                    var dash = Path()
                    dash.move(to: points[min(at, steps - 4)])
                    dash.addLine(to: points[min(at + 4, steps)])
                    context.stroke(
                        dash,
                        with: .color(accents[accentIndex % accents.count].opacity(0.9 * strength)),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round)
                    )
                    accentIndex += 1
                }
            }
        }
    }
}

/// The "— — ———————" rule from the posters: two short dashes, then a long line.
struct DashRule: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            var path = Path()
            var x: CGFloat = 0
            for length in [10.0, 10.0] {
                path.move(to: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: x + length, y: y))
                x += length + 6
            }
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        .frame(height: 1)
    }
}

/// Diagonal stripes: a leaked server's share of the bar in coral, a worktree holding work in mango.
struct Hatch: View {
    var color: Color
    var wash = 0.45

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(wash)))
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4
            }
            context.stroke(path, with: .color(color), lineWidth: 1.4)
        }
    }
}

/// The fence down the side of what's inside a row: a dashed line, after the dashed ring
/// around Corral's icon.
struct Fence: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: size.width / 2, y: 0))
            path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(width: 1)
    }
}
