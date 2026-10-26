import AppKit
import CorralCore
import SwiftUI

/// Ink neutrals, ember orange, and mango, lavender and coral accents.
public struct Palette: Sendable {
    public let isDark: Bool
    public let panel: Color
    public let card: Color
    public let hover: Color
    public let hairline: Color
    public let rim: Color
    public let track: Color
    public let text: Color
    public let text2: Color
    public let text3: Color
    public let ember: Color
    public let mango: Color
    public let lavender: Color
    public let coral: Color
    /// Coral as a button's fill, under white text.
    public let coralFill: Color
    /// Mango dark enough to read as text on the panel.
    public let mangoText: Color
    public let pink: Color
    public let graphite: Color
    public let quiet: Color
    public let mint: Color
    public let onEmber: Color

    public static let dark = Palette(
        isDark: true,
        panel: Color(hex: 0x141414),
        card: Color(hex: 0x1C1C1C),
        hover: Color.white.opacity(0.045),
        hairline: Color.white.opacity(0.08),
        rim: Color.white.opacity(0.10),
        track: Color.white.opacity(0.06),
        text: Color(hex: 0xF4F4F4),
        text2: Color(hex: 0xA3A3A3),
        text3: Color(hex: 0x6E6E6E),
        ember: Color(hex: 0xFF5214),
        mango: Color(hex: 0xFFB834),
        lavender: Color(hex: 0xBD7AFF),
        coral: Color(hex: 0xFF6967),
        coralFill: Color(hex: 0xEF4F4C),
        mangoText: Color(hex: 0xFFB834),
        pink: Color(hex: 0xFF89A5),
        graphite: Color(hex: 0x6B6B6B),
        quiet: Color(hex: 0x3A3A3A),
        mint: Color(hex: 0x3DD68C),
        onEmber: .white
    )

    public static let light = Palette(
        isDark: false,
        panel: Color(hex: 0xFFFFFF),
        card: Color(hex: 0xF6F5F3),
        hover: Color.black.opacity(0.035),
        hairline: Color.black.opacity(0.08),
        rim: Color.black.opacity(0.10),
        track: Color.black.opacity(0.06),
        text: Color(hex: 0x141414),
        text2: Color(hex: 0x5C5C5C),
        text3: Color(hex: 0x8F8F8F),
        ember: Color(hex: 0xF5490C),
        mango: Color(hex: 0xF29B00),
        lavender: Color(hex: 0xA25BF0),
        coral: Color(hex: 0xE5413E),
        coralFill: Color(hex: 0xE5413E),
        mangoText: Color(hex: 0xB36B00),
        pink: Color(hex: 0xF0708F),
        graphite: Color(hex: 0xB4B4B4),
        quiet: Color(hex: 0xDADADA),
        mint: Color(hex: 0x1FA866),
        onEmber: .white
    )

    public func color(for bucket: Bucket) -> Color {
        switch bucket {
        case .agents: ember
        case .stacks: mango
        case .build: lavender
        case .shared: graphite
        case .leaked: coral
        case .other: quiet
        }
    }

    public func color(for pressure: SystemMemory.Pressure) -> Color {
        switch pressure {
        case .normal: mint
        case .warning: mango
        case .critical: coral
        }
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.dark
}

extension EnvironmentValues {
    public var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

/// Picks the palette for the current appearance.
public struct Themed<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content.environment(\.palette, scheme == .dark ? .dark : .light)
    }
}

/// The type system: SF Pro for reading, New York italic for the wordmark, SF Mono for numbers,
/// ports and small caps labels.
public enum Typeface {
    public static func wordmark(_ size: CGFloat = 21) -> Font { .system(size: size, weight: .regular, design: .serif).italic() }
    public static let figure = Font.system(size: 36, weight: .light).monospacedDigit()
    public static let label = Font.system(size: 9.5, weight: .medium, design: .monospaced)
    public static let title = Font.system(size: 13, weight: .medium)
    public static let body = Font.system(size: 12.5)
    /// A row's one line under its name.
    public static let status = Font.system(size: 11.5)
    public static let caption = Font.system(size: 11)
    public static let number = Font.system(size: 12, weight: .medium, design: .monospaced)
    public static let smallNumber = Font.system(size: 11, design: .monospaced)
    public static let port = Font.system(size: 11, weight: .medium, design: .monospaced)
}

extension Text {
    /// Mono small caps with open tracking, the label style of the Cloud Coffee posters.
    func smallCaps(_ color: Color) -> some View {
        font(Typeface.label).tracking(1.15).textCase(.uppercase).foregroundStyle(color)
    }
}

/// How the panel moves, in one place. Whatever moves space around moves on one spring, so
/// things that move together land together; content fades in after its space starts to open
/// and fades out before its space closes. With Reduce Motion on, everything is a short fade.
@MainActor
public enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Rows opening and closing, tabs, rows coming and going, and the panel's height.
    public static var layout: Animation {
        reduced ? .easeOut(duration: 0.16) : .spring(response: 0.28, dampingFraction: 0.9)
    }
    /// A control changing what it says, like Stop arming or a toast taking the footer.
    static var swap: Animation {
        reduced ? .easeOut(duration: 0.12) : .spring(response: 0.22, dampingFraction: 0.92)
    }
    /// What's under the pointer.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Numbers and bars following a new sample. The same spring as `layout`, so rows that come
    /// or go land together with the list's height around them.
    public static var data: Animation { layout }

    /// What opens under a row: it fades in and settles a few points as the space opens up.
    /// Closing is `Fold`'s: the content fades fast, then the space folds away on `layout`.
    static var reveal: AnyTransition {
        .asymmetric(
            insertion: (reduced ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: -4)))
                .animation(.easeOut(duration: 0.18).delay(0.04)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.08))
        )
    }
    /// A tab's content comes in from the side of the tab you picked, and the one it replaces
    /// fades out first.
    static func page(from edge: HorizontalEdge) -> AnyTransition {
        .asymmetric(
            insertion: (reduced ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(x: edge == .leading ? -14 : 14)))
                .animation(.easeOut(duration: 0.2).delay(0.05)),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.08))
        )
    }
    /// A toast rises into the footer, and the footer's buttons fade back when it goes.
    static var rise: AnyTransition {
        .asymmetric(
            insertion: reduced ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 8)),
            removal: reduced ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: -4))
        )
    }
}

public enum Metrics {
    public static let panelWidth: CGFloat = 384
    public static let corner: CGFloat = 18
    public static let inset: CGFloat = 16
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
