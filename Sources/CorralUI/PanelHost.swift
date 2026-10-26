import SwiftUI

/// The panel as it sits in its window: a soft shadow around it, a quick settle when it opens,
/// and a click anywhere outside it dismisses.
public struct PanelHost: View {
    public static let shadowPadding: CGFloat = 28

    let model: PanelModel
    let dismiss: () -> Void
    @State private var appeared = false

    public init(model: PanelModel, dismiss: @escaping () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            PanelView(model: model)
                .shadow(color: .black.opacity(0.42), radius: 26, y: 14)
                .scaleEffect(appeared ? 1 : 0.975, anchor: .top)
                .opacity(appeared ? 1 : 0)
                .padding(PanelHost.shadowPadding)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            Color.clear.contentShape(Rectangle()).onTapGesture { dismiss() }
        }
        .onChange(of: model.openCount, initial: true) {
            appeared = false
            withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) { appeared = true }
        }
    }
}

/// The brand band for the settings window: wave field, wordmark and a line of copy.
public struct BrandBand: View {
    @Environment(\.colorScheme) private var scheme
    let subtitle: String

    public init(subtitle: String) {
        self.subtitle = subtitle
    }

    public var body: some View {
        let palette = scheme == .dark ? Palette.dark : Palette.light
        ZStack(alignment: .bottomLeading) {
            WaveField(line: palette.ember, accents: [palette.mango, palette.pink, palette.lavender], drift: 1, strength: palette.isDark ? 1 : 0.75)
                .mask(LinearGradient(colors: [.black.opacity(0.1), .black], startPoint: .leading, endPoint: .trailing))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Sparkle().fill(palette.ember).frame(width: 15, height: 15)
                    Text("Corral").font(Typeface.wordmark(26)).foregroundStyle(palette.text)
                }
                Text(subtitle).smallCaps(palette.text3)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
        .background(palette.panel)
    }
}
