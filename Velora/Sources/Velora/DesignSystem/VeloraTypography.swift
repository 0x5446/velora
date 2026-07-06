#if canImport(SwiftUI)
import SwiftUI

/// Warm serif headings (New York) + clean sans body (San Francisco) + a
/// monospaced accent (SF Mono) for technical bits like the elapsed timer —
/// the "warm serif + typewriter" feel, achieved with system fonts only.
public enum VeloraFont {
    public static func display(_ size: CGFloat = 20, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    public static func heading(_ size: CGFloat = 15, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    public static func body(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    public static func caption(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    public static func mono(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
#endif
