//
//  Theme.swift
//  SparkAI
//
//  Dark obsidian palette translated from the source theme/colors.ts, plus
//  the typography system (Chakra Petch display · JetBrains Mono technical)
//  and shared motion/interaction primitives.
//

import SwiftUI

enum Theme {
    static let bgPrimary = Color(hex: 0x09090B)
    static let bgSurface = Color(hex: 0x121215)
    static let bgElevated = Color(hex: 0x18181C)
    static let bgActive = Color(hex: 0x222227)

    static let border = Color.white.opacity(0.08)
    static let borderActive = Color.white.opacity(0.16)

    static let blue = Color(hex: 0x3B82F6)
    static let blueDim = Color(hex: 0x3B82F6).opacity(0.14)
    static let sky = Color(hex: 0x38BDF8)
    static let skyDim = Color(hex: 0x38BDF8).opacity(0.12)
    static let amber = Color(hex: 0xF59E0B)
    static let rose = Color(hex: 0xF43F5E)
    static let emerald = Color(hex: 0x34D399)
    static let emeraldDim = Color(hex: 0x34D399).opacity(0.14)
    static let violet = Color(hex: 0x8B5CF6)

    /// SuperServe cloud sandbox accent — deep signal blue.
    static let sandbox = Color(hex: 0x367BF0)
    static let sandboxDim = Color(hex: 0x367BF0).opacity(0.14)

    static let textPrimary = Color(hex: 0xF4F4F5)
    static let textSecondary = Color(hex: 0xA1A1AA)
    static let textTertiary = Color(hex: 0x71717A)

    /// Signature electric gradient used by the logo mark and primary actions.
    static let spark = LinearGradient(
        colors: [sky, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Typography

    /// Display face (Chakra Petch) — titles, section headers, brand.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let name: String
        switch weight {
        case .ultraLight, .thin, .light, .regular, .medium: name = "ChakraPetch-Medium"
        case .semibold: name = "ChakraPetch-SemiBold"
        default: name = "ChakraPetch-Bold"
        }
        return .custom(name, size: size)
    }

    /// Technical face (JetBrains Mono) — labels, code, telemetry, routes.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .ultraLight, .thin, .light, .regular: name = "JetBrainsMono-Regular"
        case .medium: name = "JetBrainsMono-Medium"
        case .semibold: name = "JetBrainsMono-SemiBold"
        case .bold: name = "JetBrainsMono-Bold"
        default: name = "JetBrainsMono-ExtraBold"
        }
        return .custom(name, size: size)
    }

    // MARK: - Motion

    /// House spring for taps, toggles and layout changes.
    static let snap: Animation = .spring(response: 0.32, dampingFraction: 0.78)
    /// Softer spring for sheet content and entrance reveals.
    static let reveal: Animation = .spring(response: 0.5, dampingFraction: 0.82)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Interaction primitives

/// Button style with a springy press-scale, dimming and a light haptic on
/// release — the default feel for every icon button and chip in the app.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    var haptic = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(Theme.snap, value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { wasPressed, isPressed in
                if haptic, wasPressed, !isPressed { Haptics.light() }
            }
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static func pressable(scale: CGFloat = 0.92, haptic: Bool = true) -> PressableStyle {
        PressableStyle(scale: scale, haptic: haptic)
    }
}

/// Square 36pt header/toolbar icon button with the obsidian chip treatment.
struct IconChip: View {
    let systemName: String
    var tint: Color = Theme.textSecondary
    var isActive = false
    var size: CGFloat = 36
    var cornerRadius: CGFloat = 11

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(isActive ? tint : Theme.textSecondary)
            .frame(width: size, height: size)
            .background(isActive ? tint.opacity(0.14) : Theme.bgSurface, in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(isActive ? tint.opacity(0.42) : Theme.border)
            )
            .shadow(color: isActive ? tint.opacity(0.28) : .clear, radius: 10, y: 2)
            .contentTransition(.symbolEffect(.replace))
            .animation(Theme.snap, value: isActive)
    }
}

/// Staggered entrance: fades and lifts the view in after `delay` seconds.
struct EntranceModifier: ViewModifier {
    let delay: Double
    let offset: CGFloat
    @State private var isShown = false

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : offset)
            .blur(radius: isShown ? 0 : 6)
            .onAppear {
                withAnimation(Theme.reveal.delay(delay)) { isShown = true }
            }
    }
}

extension View {
    /// Staggered fade-lift entrance for lists and hero content.
    func entrance(delay: Double = 0, offset: CGFloat = 14) -> some View {
        modifier(EntranceModifier(delay: delay, offset: offset))
    }
}
