import SwiftUI

enum InCamTheme {
    static let ivory = Color(red: 0.94, green: 0.92, blue: 0.86)
    static let graphite = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let green = Color(red: 0.35, green: 0.9, blue: 0.5)
    static let record = Color(red: 0.95, green: 0.11, blue: 0.12)
}

struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    var emphasized = false

    func body(content: Content) -> some View {
        content
            // Material supplies the Gaussian-style system blur; the low-alpha
            // gradient lets the live scene's colors subtly influence every
            // control without sacrificing label contrast.
            .background(.ultraThinMaterial, in: shape)
            .background(
                LinearGradient(colors: [
                    .white.opacity(emphasized ? 0.16 : 0.1),
                    InCamTheme.graphite.opacity(emphasized ? 0.58 : 0.3),
                    .black.opacity(emphasized ? 0.28 : 0.14),
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: shape
            )
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(emphasized ? 0.3 : 0.18), .white.opacity(0.04)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
    }
}

extension View {
    func glass<S: Shape>(in shape: S, emphasized: Bool = false) -> some View {
        modifier(GlassSurface(shape: shape, emphasized: emphasized))
    }
}

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
