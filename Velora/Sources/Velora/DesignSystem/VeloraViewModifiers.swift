#if canImport(SwiftUI)
import SwiftUI

/// Flat warm "index card" surface: opaque `veloraSurface` fill, hairline
/// `veloraBorder` stroke, warm-tinted shadow. Used for focused/positioned
/// panels (e.g. the translation review card) as opposed to the
/// click-through HUD, which keeps `.ultraThinMaterial` instead.
public struct VeloraCardBackground: ViewModifier {
    var radius: CGFloat = VeloraRadius.large
    var elevation: VeloraElevation = .high

    public func body(content: Content) -> some View {
        content
            .background(Color.veloraSurface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.veloraBorder, lineWidth: 1)
            )
            .veloraShadow(elevation)
    }
}

public extension View {
    func veloraCard(radius: CGFloat = VeloraRadius.large, elevation: VeloraElevation = .high) -> some View {
        modifier(VeloraCardBackground(radius: radius, elevation: elevation))
    }
}

/// Shared `TextEditor` chrome, consolidating the three different
/// translucency/stroke recipes previously duplicated across the review
/// panel's source/target editors, the settings dev text-lab panel, and the
/// iOS prototype's ASR editors.
public struct VeloraTextEditorBackground: ViewModifier {
    var isFocused: Bool

    public func body(content: Content) -> some View {
        content
            .background(Color.veloraBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: VeloraRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VeloraRadius.small, style: .continuous)
                    .stroke(isFocused ? Color.veloraAccent.opacity(0.8) : Color.veloraBorder, lineWidth: isFocused ? 1.5 : 1)
            )
    }
}

public extension View {
    func veloraTextEditorStyle(isFocused: Bool) -> some View {
        modifier(VeloraTextEditorBackground(isFocused: isFocused))
    }
}
#endif
