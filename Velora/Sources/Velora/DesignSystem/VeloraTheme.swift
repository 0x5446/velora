// Tech-retro design tokens: warm paper background, warm near-black ink,
// clay/terracotta accent used sparingly, warm-tinted shadows. Inspired by
// (not copied from) contemporary "warm analog-tech" product design.
// Single source of truth, consumed by VeloraMacApp, VeloraiOS, and
// VeloraKeyboard — all three already depend on this package.

#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Raw hex values — the single source of truth. Every platform-specific
/// color type below is derived from these, never hand-duplicated.
/// Keep these byte-for-byte in sync with `scripts/generate_app_icon.py`.
public enum VeloraPalette {
    public static let backgroundLight: UInt32 = 0xF7F3EA
    public static let surfaceLight: UInt32 = 0xFBF8F2
    public static let borderLight: UInt32 = 0xE1D7C0
    public static let inkPrimaryLight: UInt32 = 0x2B2621
    public static let inkSecondaryLight: UInt32 = 0x6B6255

    public static let backgroundDark: UInt32 = 0x1E1A16
    public static let surfaceDark: UInt32 = 0x28231D
    public static let borderDark: UInt32 = 0x3C352B
    public static let inkPrimaryDark: UInt32 = 0xEDE6D9
    public static let inkSecondaryDark: UInt32 = 0xA79C8A

    public static let accentLight: UInt32 = 0xBF5B3A
    public static let accentDark: UInt32 = 0xD97A50
    public static let accentMutedLight: UInt32 = 0xEDD9C7
    public static let accentMutedDark: UInt32 = 0x4A3626

    public static let dangerLight: UInt32 = 0xAE3A2E
    public static let dangerDark: UInt32 = 0xC1584A
    public static let successLight: UInt32 = 0x5C7A4B
    public static let successDark: UInt32 = 0x7FA05E
}

#if canImport(UIKit)
public extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static let veloraBackground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: VeloraPalette.backgroundDark) : UIColor(hex: VeloraPalette.backgroundLight) }
    static let veloraSurface = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: VeloraPalette.surfaceDark) : UIColor(hex: VeloraPalette.surfaceLight) }
    static let veloraBorder = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: VeloraPalette.borderDark) : UIColor(hex: VeloraPalette.borderLight) }
    static let veloraInkPrimary = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: VeloraPalette.inkPrimaryDark) : UIColor(hex: VeloraPalette.inkPrimaryLight) }
    static let veloraInkSecondary = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: VeloraPalette.inkSecondaryDark) : UIColor(hex: VeloraPalette.inkSecondaryLight) }
    static let veloraAccent = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: VeloraPalette.accentDark) : UIColor(hex: VeloraPalette.accentLight) }
    static let veloraDanger = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: VeloraPalette.dangerDark) : UIColor(hex: VeloraPalette.dangerLight) }
    static let veloraSuccess = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: VeloraPalette.successDark) : UIColor(hex: VeloraPalette.successLight) }
}
#endif

#if canImport(AppKit)
public extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func veloraDynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    static let veloraBackground = veloraDynamic(light: VeloraPalette.backgroundLight, dark: VeloraPalette.backgroundDark)
    static let veloraSurface = veloraDynamic(light: VeloraPalette.surfaceLight, dark: VeloraPalette.surfaceDark)
    static let veloraBorder = veloraDynamic(light: VeloraPalette.borderLight, dark: VeloraPalette.borderDark)
    static let veloraInkPrimary = veloraDynamic(light: VeloraPalette.inkPrimaryLight, dark: VeloraPalette.inkPrimaryDark)
    static let veloraInkSecondary = veloraDynamic(light: VeloraPalette.inkSecondaryLight, dark: VeloraPalette.inkSecondaryDark)
    static let veloraAccent = veloraDynamic(light: VeloraPalette.accentLight, dark: VeloraPalette.accentDark)
    static let veloraDanger = veloraDynamic(light: VeloraPalette.dangerLight, dark: VeloraPalette.dangerDark)
    static let veloraSuccess = veloraDynamic(light: VeloraPalette.successLight, dark: VeloraPalette.successDark)
}
#endif

#if canImport(SwiftUI)
public extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #elseif canImport(AppKit)
        return Color(NSColor.veloraDynamic(light: light, dark: dark))
        #else
        return Color(hex: light)
        #endif
    }

    static let veloraBackground = dynamic(VeloraPalette.backgroundLight, VeloraPalette.backgroundDark)
    static let veloraSurface = dynamic(VeloraPalette.surfaceLight, VeloraPalette.surfaceDark)
    static let veloraBorder = dynamic(VeloraPalette.borderLight, VeloraPalette.borderDark)
    static let veloraInkPrimary = dynamic(VeloraPalette.inkPrimaryLight, VeloraPalette.inkPrimaryDark)
    static let veloraInkSecondary = dynamic(VeloraPalette.inkSecondaryLight, VeloraPalette.inkSecondaryDark)
    static let veloraAccent = dynamic(VeloraPalette.accentLight, VeloraPalette.accentDark)
    static let veloraAccentMuted = dynamic(VeloraPalette.accentMutedLight, VeloraPalette.accentMutedDark)
    static let veloraDanger = dynamic(VeloraPalette.dangerLight, VeloraPalette.dangerDark)
    static let veloraSuccess = dynamic(VeloraPalette.successLight, VeloraPalette.successDark)
}
#endif
