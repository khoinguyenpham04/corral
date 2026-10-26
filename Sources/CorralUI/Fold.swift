import SwiftUI

/// What opens in place under a row. Its space opens on the panel's spring while its content
/// fades in; on closing, the content fades out quickly while the space folds away on the same
/// spring. Either way the list's height follows it frame by frame, so it never jumps, the rows
/// below never slide over content that isn't there yet, and a scrolled list never snaps.
struct Fold<Content: View>: View {
    let open: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.folds) private var folds
    /// In the hierarchy: open, or still folding away.
    @State private var mounted: Bool
    @State private var fraction: CGFloat
    @State private var opacity: Double = 1
    @State private var moving = false
    /// Bumped by every open and close, so the end of an earlier one doesn't cut a later one short.
    @State private var generation = 0

    init(open: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.open = open
        self.content = content
        _mounted = State(initialValue: open)
        _fraction = State(initialValue: open ? 1 : 0)
    }

    var body: some View {
        Group {
            if open || mounted {
                Unfold(fraction: fraction) {
                    VStack(alignment: .leading, spacing: 0) { content() }
                }
                .clipped()
                .opacity(opacity)
                .transition(Motion.reveal)
            }
        }
        .onChange(of: open) { _, isOpen in
            if isOpen { unfold() } else { fold() }
        }
        .onDisappear { setMoving(false) }
    }

    private func unfold() {
        generation += 1
        let current = generation
        mounted = true
        setMoving(true)
        // Opened again while it was still folding away.
        withAnimation(.easeOut(duration: 0.2)) { opacity = 1 }
        withAnimation(Motion.layout) {
            fraction = 1
        } completion: {
            guard generation == current else { return }
            setMoving(false)
        }
    }

    private func fold() {
        generation += 1
        let current = generation
        setMoving(true)
        withAnimation(.easeOut(duration: 0.08)) { opacity = 0 }
        withAnimation(Motion.layout) {
            fraction = 0
        } completion: {
            guard moving, generation == current else { return }
            setMoving(false)
            // Gone for good: out of the hierarchy, and closed, ready to open from nothing next time.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                mounted = false
                opacity = 1
            }
        }
    }

    private func setMoving(_ value: Bool) {
        guard moving != value else { return }
        moving = value
        folds?.active += value ? 1 : -1
    }
}

/// Lays its content out at full height, but takes up only `fraction` of it.
struct Unfold: Layout {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = natural(proposal, subviews)
        return CGSize(width: size.width, height: size.height * min(1, max(0, fraction)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = natural(proposal, subviews)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
    }

    private func natural(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
    }
}

/// How many rows are opening or folding away right now. While any is, the panel's list follows
/// their height frame by frame instead of springing after it.
@MainActor
final class FoldTracker {
    var active = 0
}

private struct FoldTrackerKey: EnvironmentKey {
    static let defaultValue: FoldTracker? = nil
}

private struct OpeningKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var folds: FoldTracker? {
        get { self[FoldTrackerKey.self] }
        set { self[FoldTrackerKey.self] = newValue }
    }

    /// Counts the panel's openings. The panel can hide under the pointer without a word to the
    /// views beneath it, so what lights up on hover starts each opening unlit.
    var opening: Int {
        get { self[OpeningKey.self] }
        set { self[OpeningKey.self] = newValue }
    }
}
