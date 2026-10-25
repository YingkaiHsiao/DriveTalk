import SwiftUI
import UIKit

/// App-wide look: follows the iPhone light / dark setting automatically.
enum Theme {
    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    // Background gradient
    static let bgTop = dynamic(light: hex(0xF3F6FF), dark: hex(0x0B1022))
    static let bgBottom = dynamic(light: hex(0xE6EEFF), dark: hex(0x161E3A))

    // Brand + states (each readable on its own background in both modes)
    static let accent = dynamic(light: hex(0x4F46E5), dark: hex(0x818CF8))
    static let listen = dynamic(light: hex(0x059669), dark: hex(0x34D399))
    static let think = dynamic(light: hex(0xD97706), dark: hex(0xFBBF24))
    static let speak = dynamic(light: hex(0x2563EB), dark: hex(0x60A5FA))
    static let pause = dynamic(light: hex(0xEA580C), dark: hex(0xFB923C))
    static let idle = dynamic(light: hex(0x64748B), dark: hex(0x94A3B8))

    /// Text colors for coloured captions (good contrast in light mode too).
    static let heard = dynamic(light: hex(0x047857), dark: hex(0x6EE7B7))
    static let tip = dynamic(light: hex(0xB45309), dark: hex(0xFCD34D))
    static let tipBackground = dynamic(light: hex(0xFEF3C7), dark: hex(0x3A2E0B))

    static let card = dynamic(light: UIColor.white.withAlphaComponent(0.85), dark: UIColor.white.withAlphaComponent(0.07))
    static let cardStroke = dynamic(light: UIColor.black.withAlphaComponent(0.06), dark: UIColor.white.withAlphaComponent(0.10))
    static let chip = dynamic(light: hex(0xEEF2FF), dark: UIColor.white.withAlphaComponent(0.10))

    static let startGradient = LinearGradient(colors: [Color(red: 0.06, green: 0.73, blue: 0.51), Color(red: 0.05, green: 0.58, blue: 0.80)],
                                              startPoint: .leading, endPoint: .trailing)
    static let stopGradient = LinearGradient(colors: [Color(red: 0.94, green: 0.27, blue: 0.27), Color(red: 0.86, green: 0.15, blue: 0.47)],
                                             startPoint: .leading, endPoint: .trailing)
}

/// Full-screen soft gradient behind the content.
struct AppBackground: View {
    var body: some View {
        LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 12, y: 4)
    }
}

extension View {
    /// Rounded card used across the app.
    func themeCard(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }

    /// Gradient background behind lists / scroll views.
    func themeBackground() -> some View {
        self.scrollContentBackground(.hidden).background(AppBackground())
    }
}

/// Small rounded label.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var color: Color = Theme.accent

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.chip, in: Capsule())
    }
}
