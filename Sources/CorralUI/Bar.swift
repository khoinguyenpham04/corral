import CorralCore
import SwiftUI

/// What the pointer is over: a row, or a piece of the bar. The pieces of the worktree it
/// belongs to stay lit while the rest dim, and the piece under the pointer is named under the bar.
@MainActor @Observable
final class Focus {
    /// The worktree (or "shared") whose pieces stay lit.
    var owner: String?
    /// The piece under the pointer, and where its middle is along the bar.
    var piece: BarPiece?
    var pieceMidX: CGFloat = 0
    /// Counts the times the pointer came onto the bar, so its label fades in where it belongs
    /// instead of gliding over from where it was last time.
    var visit = 0

    func clear() {
        owner = nil
        piece = nil
    }

    func hover(_ owner: String, _ inside: Bool) {
        if inside {
            self.owner = owner
        } else if self.owner == owner {
            self.owner = nil
        }
    }
}

/// One worktree's share of one kind of memory, or one idle worktree's share of the disk.
struct BarPiece: Identifiable, Equatable {
    enum Fill: Equatable {
        case solid(Color)
        case hatch(Color)
    }

    let id: String
    /// The row it belongs to, so hovering either lights the other.
    let owner: String
    let label: String
    let bytes: UInt64
    let fill: Fill
}

/// The pieces of one kind, kept together: Corral's colour by kind, a piece per worktree inside it.
struct BarGroup: Identifiable, Equatable {
    let id: String
    let pieces: [BarPiece]

    var bytes: UInt64 { pieces.reduce(0) { $0 + $1.bytes } }
}

enum Bars {
    /// The bar's order: what you can act on first, then what everything shares.
    static let kinds: [Bucket] = [.agents, .stacks, .build, .leaked, .shared, .other]

    static func fill(_ bucket: Bucket, _ palette: Palette) -> BarPiece.Fill {
        bucket == .leaked ? .hatch(palette.coral) : .solid(palette.color(for: bucket))
    }

    static func memory(_ snapshot: Snapshot, palette: Palette) -> [BarGroup] {
        kinds.compactMap { kind in
            var pieces = snapshot.checkouts.compactMap { checkout -> BarPiece? in
                let bytes = checkout.breakdown[kind]
                guard bytes > 0 else { return nil }
                return BarPiece(id: kind.rawValue + checkout.id, owner: checkout.id, label: "\(checkout.name) · \(kind.label.lowercased())", bytes: bytes, fill: fill(kind, palette))
            }
            if kind == .shared, snapshot.sharedMemory > 0 {
                pieces.append(BarPiece(id: "shared", owner: "shared", label: "Shared", bytes: snapshot.sharedMemory, fill: fill(.shared, palette)))
            }
            return pieces.isEmpty ? nil : BarGroup(id: kind.rawValue, pieces: pieces)
        }
    }

    static func rail(_ checkout: Checkout, palette: Palette) -> [BarPiece] {
        let breakdown = checkout.breakdown
        return kinds.filter { breakdown[$0] > 0 }.map {
            BarPiece(id: $0.rawValue, owner: checkout.id, label: $0.label, bytes: breakdown[$0], fill: fill($0, palette))
        }
    }

    /// Safe ones in ink, each a little lighter than the one before; ones holding work in mango hatch.
    static func disk(_ report: DiskReport, palette: Palette) -> [BarGroup] {
        let measured = report.worktrees.filter { ($0.usage?.freeable ?? 0) > 0 }
        let safe = measured.filter(\.canTrash).enumerated().map { index, item in
            piece(item, .solid(palette.text.opacity(max(0.3, 0.9 - Double(index) * 0.08))))
        }
        let held = measured.filter { !$0.holds.isEmpty }.map { piece($0, .hatch(palette.mango)) }
        let unchecked = measured.filter { !$0.canTrash && $0.holds.isEmpty }.map { piece($0, .solid(palette.graphite)) }
        return [BarGroup(id: "safe", pieces: safe), BarGroup(id: "held", pieces: held), BarGroup(id: "unchecked", pieces: unchecked)]
            .filter { !$0.pieces.isEmpty }
    }

    private static func piece(_ item: IdleWorktree, _ fill: BarPiece.Fill) -> BarPiece {
        BarPiece(id: item.id, owner: "disk:" + item.id, label: item.worktree.name, bytes: item.usage?.freeable ?? 0, fill: fill)
    }
}

/// Groups of pieces against a track that stands for `scale`. Hovering a piece lights its
/// worktree and names it underneath; `reveal` sweeps it in from the left when the panel opens.
struct SplitBar: View {
    @Environment(\.palette) private var palette
    @Environment(Focus.self) private var focus
    let groups: [BarGroup]
    let scale: UInt64
    var height: CGFloat = 8
    var gap: CGFloat = 2
    var reveal: CGFloat = 1

    private struct Placed: Identifiable {
        let id: String
        let x: CGFloat
        let width: CGFloat
        let pieces: [PlacedPiece]
    }

    private struct PlacedPiece: Identifiable {
        let piece: BarPiece
        let x: CGFloat
        let width: CGFloat
        var id: String { piece.id }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let placed = place(width: width)
            let lit = focus.owner.flatMap { owner in groups.contains { $0.pieces.contains { $0.owner == owner } } ? owner : nil }
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                ForEach(placed) { group in
                    HStack(spacing: 0) {
                        ForEach(group.pieces) { item in
                            BarFill(fill: item.piece.fill)
                                .frame(width: item.width)
                                .opacity(lit == nil || item.piece.owner == lit ? 1 : 0.2)
                        }
                    }
                    .frame(width: group.width, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: min(2, height / 2), style: .continuous))
                    .offset(x: group.x)
                }
            }
            .frame(width: width, height: height, alignment: .leading)
            .mask(alignment: .leading) { Rectangle().frame(width: width * reveal) }
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.18), value: lit)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case let .active(point) = phase,
                      let hit = placed.flatMap(\.pieces).first(where: { point.x >= $0.x && point.x < $0.x + $0.width })
                else {
                    if focus.piece != nil { withAnimation(.easeOut(duration: 0.12)) { focus.piece = nil } }
                    focus.owner = nil
                    return
                }
                let mid = hit.x + hit.width / 2
                if focus.piece == nil {
                    focus.visit += 1
                    focus.pieceMidX = mid
                    withAnimation(.easeOut(duration: 0.12)) { focus.piece = hit.piece }
                } else if focus.piece != hit.piece {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                        focus.piece = hit.piece
                        focus.pieceMidX = mid
                    }
                }
                focus.owner = hit.piece.owner
            }
            .overlay(alignment: .topLeading) { tip(width: width) }
        }
        .frame(height: height)
    }

    /// The piece under the pointer, named just under the bar. It glides from piece to piece.
    private func tip(width: CGFloat) -> some View {
        let shown = focus.piece.flatMap { piece in groups.contains { $0.pieces.contains(piece) } ? piece : nil }
        let mid = focus.pieceMidX
        let below = height + 6
        return ZStack(alignment: .topLeading) {
            if let piece = shown {
                BarTip(piece: piece)
                    .alignmentGuide(.leading) { dimensions in
                        -min(max(mid - dimensions.width / 2, 0), max(width - dimensions.width, 0))
                    }
                    .alignmentGuide(.top) { _ in -below }
                    .id(focus.visit)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
    }

    private func place(width: CGFloat) -> [Placed] {
        let usable = max(0, width - gap * CGFloat(max(groups.count - 1, 0)))
        let total = Double(max(scale, groups.reduce(0) { $0 + $1.bytes }, 1))
        var x: CGFloat = 0
        return groups.map { group in
            let groupWidth = max(2, usable * CGFloat(Double(group.bytes) / total))
            var pieceX = x
            let pieces = group.pieces.map { piece in
                let pieceWidth = groupWidth * CGFloat(Double(piece.bytes) / Double(max(group.bytes, 1)))
                defer { pieceX += pieceWidth }
                return PlacedPiece(piece: piece, x: pieceX, width: pieceWidth)
            }
            defer { x += groupWidth + gap }
            return Placed(id: group.id, x: x, width: groupWidth, pieces: pieces)
        }
    }
}

/// A piece's colour, or its stripes.
struct BarFill: View {
    let fill: BarPiece.Fill

    var body: some View {
        switch fill {
        case let .solid(color): Rectangle().fill(color)
        case let .hatch(color): Hatch(color: color)
        }
    }
}

struct BarTip: View {
    @Environment(\.palette) private var palette
    let piece: BarPiece

    var body: some View {
        HStack(spacing: 6) {
            Text(piece.label).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.text)
            Text(Format.bytes(piece.bytes)).font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(palette.text2)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(palette.rim, lineWidth: 1))
        .shadow(color: .black.opacity(palette.isDark ? 0.35 : 0.12), radius: 10, y: 5)
        .fixedSize()
    }
}

/// Small caps names for what the bar's colours mean.
struct BarLegend: View {
    struct Item: Identifiable {
        let label: String
        let fill: BarPiece.Fill
        var id: String { label }
    }

    @Environment(\.palette) private var palette
    let items: [Item]

    var body: some View {
        HStack(spacing: 13) {
            ForEach(items) { item in
                HStack(spacing: 5) {
                    BarFill(fill: item.fill).frame(width: 7, height: 7).clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
                    Text(item.label).smallCaps(palette.text2)
                }
            }
        }
    }
}

/// A worktree's slice of the bar, standing beside its name: what kinds of thing use its memory.
struct Rail: View {
    let pieces: [BarPiece]

    var body: some View {
        ShareStack(shares: pieces.map { Double($0.bytes) }) {
            ForEach(pieces) { BarFill(fill: $0.fill) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
    }
}

/// Stacks its subviews top to bottom, each as tall as its share, and never shorter than `minimum`.
struct ShareStack: Layout {
    var shares: [Double]
    var spacing: CGFloat = 1.5
    var minimum: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 3, height: proposal.height ?? 32)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = Self.heights(shares, in: bounds.height - spacing * CGFloat(max(subviews.count - 1, 0)), minimum: minimum)
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
            y += height + spacing
        }
    }

    /// Shares of `space`, where the small ones get `minimum` and the rest split what's left.
    static func heights(_ shares: [Double], in space: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let total = shares.reduce(0, +)
        guard total > 0, space > 0 else { return shares.map { _ in 0 } }
        let small = shares.map { CGFloat($0 / total) * space < minimum }
        let fixed = CGFloat(small.filter { $0 }.count) * minimum
        let rest = shares.indices.filter { !small[$0] }.reduce(0) { $0 + shares[$1] }
        return shares.indices.map { index in
            small[index] ? minimum : max(minimum, CGFloat(shares[index] / max(rest, 1)) * max(0, space - fixed))
        }
    }
}
