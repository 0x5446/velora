#if canImport(SwiftUI)
import SwiftUI

/// Corner-radius scale, replacing the hardcoded 6/7/8/12 literals scattered
/// across the app. The floating HUD stays a `Capsule`, untouched by this
/// scale.
public enum VeloraRadius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 10
    public static let large: CGFloat = 16
}

/// Warm-tinted elevation shadows (derived from `veloraInkPrimary`, not pure
/// black) at two levels, replacing the two different ad hoc black-shadow
/// recipes previously used by the HUD pill and the review panel.
public enum VeloraElevation {
    case low
    case high

    var radius: CGFloat { self == .low ? 14 : 24 }
    var y: CGFloat { self == .low ? 5 : 10 }
    var opacity: Double { self == .low ? 0.14 : 0.20 }
}

public extension View {
    func veloraShadow(_ elevation: VeloraElevation) -> some View {
        shadow(color: Color.veloraInkPrimary.opacity(elevation.opacity), radius: elevation.radius, y: elevation.y)
    }
}
#endif
