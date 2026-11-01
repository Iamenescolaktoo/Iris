import SwiftUI

enum PreviewLayout {
    static func frame(in size: CGSize, ratio: CompositionRatio, portrait: Bool, safeLeft: CGFloat = 0, safeRight: CGFloat = 0, adjustmentExpanded: Bool = false, rightControls: CGFloat = 100) -> CGRect {
        // The grey thumb-control strip is fixed. The preview may never claim
        // that space, even when a dock or inspector is expanded.
        let bounds = portrait ? CGRect(origin: .zero, size: size)
            : CGRect(x: 0, y: 0, width: max(1, size.width - rightControls), height: size.height)
        return CGRect(x: bounds.minX, y: 0, width: bounds.width, height: size.height)
    }
}

struct CompositionOverlay: View {
    var safeLeft: CGFloat = 0
    var safeRight: CGFloat = 0
    var adjustmentExpanded = false
    var rightControls: CGFloat = 100
    var framingEnabled = true
    // Keep the viewport geometry and border available without displaying it.
    var viewportOutlineVisible = false
    let ratio: CompositionRatio
    let grid: GridMode
    let gridDensity: Int
    let levelEnabled: Bool
    let roll: Double
    let pitch: Double
    /// Calculated by CameraController from gravity with smoothing, snap, and
    /// hysteresis; the view only draws that measured state.
    let levelIsCentered: Bool
    let isPortrait: Bool

    /// Landscape 16:9 uses the preview's full visible rectangle after it has
    /// been zoomed to crop cleanly. Showing another guide/mask over it would
    /// reveal artificial edges and defeat that camera-style presentation.
    private var fillsViewport: Bool { !isPortrait && ratio == .sixteenNine }

    var body: some View {
        GeometryReader { proxy in
            let viewport = PreviewLayout.frame(in: proxy.size, ratio: ratio, portrait: isPortrait, safeLeft: safeLeft, safeRight: safeRight,
                                               adjustmentExpanded: adjustmentExpanded, rightControls: rightControls)
            let frame = fillsViewport ? viewport : guideFrame(in: proxy.size)
            ZStack {
                if framingEnabled && !fillsViewport {
                    // Material gives unused ratio areas a Gaussian-style live
                    // blur instead of a flat black or transparent-black mask.
                    let localFrame = frame.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .frame(width: viewport.width, height: viewport.height)
                        .mask {
                            Path { path in
                                // The blurred unused area follows the same
                                // continuous, rounded camera contour as the
                                // dock/control surface. A square mask here
                                // was the source of the hard rectangle beside
                                // the mousepad on non-16:9 guides.
                                path.addRoundedRect(in: CGRect(origin: .zero, size: viewport.size),
                                                    cornerSize: CGSize(width: 22, height: 22))
                                path.addRoundedRect(in: localFrame,
                                                    cornerSize: CGSize(width: 22, height: 22))
                            }
                            .fill(.white, style: FillStyle(eoFill: true))
                        }
                        .position(x: viewport.midX, y: viewport.midY)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(InCamTheme.ivory.opacity(0.4), lineWidth: 1)
                        .frame(width: viewport.width, height: viewport.height)
                        .position(x: viewport.midX, y: viewport.midY)
                        .opacity(viewportOutlineVisible ? 1 : 0)
                    // The framing rectangle is visibly rounded on every
                    // ratio; it is never the square edge of the full preview.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(InCamTheme.ivory.opacity(0.28), lineWidth: 0.8)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }

                gridView
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .position(x: frame.midX, y: frame.midY)

                if levelEnabled {
                    HorizonLevel(roll: roll, isCentered: levelIsCentered)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var gridView: some View {
        switch grid {
        case .off: EmptyView()
        // Rule of Thirds is always a true 3 × 3 guide. It must not inherit a
        // generic density value and turn into a mismatched 4 × 4 guide inside
        // a selected 4:3, 16:9, or square composition frame.
        case .thirds: ThirdsGrid(golden: false, divisions: 3)
        case .golden: ThirdsGrid(golden: true, divisions: gridDensity)
        case .spiral: GoldenSpiral(mirrored: isPortrait)
        case .diagonals: DiagonalGrid()
        }
    }

    private func guideFrame(in size: CGSize) -> CGRect {
        let viewport = PreviewLayout.frame(in: size, ratio: ratio, portrait: isPortrait, safeLeft: safeLeft, safeRight: safeRight,
                            adjustmentExpanded: adjustmentExpanded, rightControls: rightControls)
        guard framingEnabled else { return viewport }
        let aspect = isPortrait ? 1 / ratio.value : ratio.value
        let width = min(viewport.width, viewport.height * aspect)
        return CGRect(x: viewport.midX - width / 2, y: (viewport.height - width / aspect) / 2,
                      width: width, height: width / aspect)
    }
}

private struct ThirdsGrid: View {
    let golden: Bool
    let divisions: Int
    var body: some View {
        Canvas { context, size in
            let safeDivisions = max(2, min(6, divisions))
            let values: [CGFloat] = golden
                ? [0.382, 0.618]
                : (1..<safeDivisions).map { CGFloat($0) / CGFloat(safeDivisions) }
            for value in values {
                var vertical = Path()
                vertical.move(to: CGPoint(x: size.width * value, y: 0))
                vertical.addLine(to: CGPoint(x: size.width * value, y: size.height))
                context.stroke(vertical, with: .color(.white.opacity(0.46)), lineWidth: 0.7)
                var horizontal = Path()
                horizontal.move(to: CGPoint(x: 0, y: size.height * value))
                horizontal.addLine(to: CGPoint(x: size.width, y: size.height * value))
                context.stroke(horizontal, with: .color(.white.opacity(0.46)), lineWidth: 0.7)
            }
        }
    }
}

private struct DiagonalGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: .zero); path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.move(to: CGPoint(x: size.width, y: 0)); path.addLine(to: CGPoint(x: 0, y: size.height))
            path.move(to: CGPoint(x: size.width / 2, y: 0)); path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            path.move(to: CGPoint(x: 0, y: size.height / 2)); path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(path, with: .color(.white.opacity(0.46)), lineWidth: 0.7)
        }
    }
}

struct GridChoiceIcon: View {
    let mode: GridMode
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                let rect = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 1, dy: 1)
                path.addRoundedRect(in: rect, cornerSize: CGSize(width: 2, height: 2))
                if mode == .off {
                    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                } else if mode == .diagonals {
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.midX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.midY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                } else {
                    let stops = mode == .golden ? [0.382, 0.618] : [1.0 / 3, 2.0 / 3]
                    for stop in stops {
                        let x = rect.minX + rect.width * stop, y = rect.minY + rect.height * stop
                        path.move(to: CGPoint(x: x, y: rect.minY)); path.addLine(to: CGPoint(x: x, y: rect.maxY))
                        path.move(to: CGPoint(x: rect.minX, y: y)); path.addLine(to: CGPoint(x: rect.maxX, y: y))
                    }
                }
            }.stroke(lineWidth: 1)
        }
    }
}

private struct GoldenSpiral: View {
    let mirrored: Bool
    var body: some View {
        Canvas { context, size in
            var path = Path()
            // Quarter-circles in contiguous Fibonacci squares, fitted without distortion.
            let arcs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (34, 34, 34, 180), (34, 21, 21, 270), (42, 21, 13, 0),
                (42, 26, 8, 90), (39, 26, 5, 180), (39, 24, 3, 270),
                (40, 24, 2, 0), (40, 25, 1, 90), (40, 25, 1, 180)
            ]
            let scale = min(size.width / 55, size.height / 34)
            let offset = CGPoint(x: (size.width - 55 * scale) / 2, y: (size.height - 34 * scale) / 2)
            for (arcIndex, arc) in arcs.enumerated() {
                for step in 0...24 {
                    let angle = (arc.3 + CGFloat(step) * 90 / 24) * .pi / 180
                    let x = (arc.0 + cos(angle) * arc.2) * scale + offset.x
                    let point = CGPoint(x: mirrored ? size.width - x : x,
                                        y: (arc.1 + sin(angle) * arc.2) * scale + offset.y)
                    if arcIndex == 0 && step == 0 { path.move(to: point) }
                    else { path.addLine(to: point) }
                }
            }
            context.stroke(path, with: .color(.white.opacity(0.48)), lineWidth: 0.8)
        }
    }
}

private struct HorizonLevel: View {
    let roll: Double
    let isCentered: Bool
    /// Gravity is measured in the phone sensor's portrait basis. In InCam's
    /// landscape camera UI, that makes a level horizon appear vertical, so
    /// the visual baseline is rotated a quarter turn. The bar is horizontal
    /// when the phone is level and rolls around that baseline.
    private var angle: Angle { .degrees(roll + 90) }

    var body: some View {
        ZStack {
            Capsule()
                .fill(isCentered ? InCamTheme.green : InCamTheme.ivory.opacity(0.94))
                .frame(width: 58, height: 2)
                .rotationEffect(angle)
            .shadow(color: isCentered ? InCamTheme.green.opacity(0.95) : .clear, radius: isCentered ? 7 : 0)
        }
        .frame(width: 140, height: 140)
        .shadow(color: .black.opacity(0.5), radius: 2)
        .animation(nil, value: roll)
    }
}

struct RecordingEdgeGlow: View {
    /// Full-screen recording uses the device container's own continuous
    /// contour. Composition ratios use a proportional rounded rectangle.
    var followsDeviceContour = false
    var cornerRadius: CGFloat = 24

    var body: some View {
        Group {
            if followsDeviceContour {
                ZStack {
                    ContainerRelativeShape()
                        .strokeBorder(InCamTheme.record.opacity(0.36), lineWidth: 3)
                        .blur(radius: 4)
                    ContainerRelativeShape()
                        .strokeBorder(recordingGradient, lineWidth: 2)
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(InCamTheme.record.opacity(0.36), lineWidth: 3)
                        .blur(radius: 4)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(recordingGradient, lineWidth: 2)
                }
            }
        }
        // Keep the luminous two-point line inside its true viewport, so it
        // never overlaps the live image with the surrounding app padding.
        .padding(2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: cornerRadius)
    }

    private var recordingGradient: LinearGradient {
        LinearGradient(
            colors: [InCamTheme.record.opacity(0.72), InCamTheme.record, Color(red: 1, green: 0.42, blue: 0.42), InCamTheme.record],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
