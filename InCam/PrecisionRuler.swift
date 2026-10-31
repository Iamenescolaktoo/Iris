import SwiftUI

private struct VerticalCameraRulerKey: EnvironmentKey { static let defaultValue = false }
private struct CameraRulerHeightKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    var cameraRulerHeight: CGFloat? {
        get { self[CameraRulerHeightKey.self] }
        set { self[CameraRulerHeightKey.self] = newValue }
    }
    var verticalCameraRuler: Bool {
        get { self[VerticalCameraRulerKey.self] }
        set { self[VerticalCameraRulerKey.self] = newValue }
    }
}

struct PrecisionRuler: View {
    @Environment(\.verticalCameraRuler) private var vertical
    @Environment(\.cameraRulerHeight) private var heightOverride
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var verticalHeight: CGFloat = 164
    var showsValue = true
    var tickColor: ((Double) -> Color)? = nil
    var accessibilityID = "controls.ruler"
    var valueFontSize: CGFloat = 18
    var unit: String? = nil
    let formatter: (Double) -> String

    @State private var gestureStart: Double?
    @State private var dragDisplayValue: Double?

    var body: some View {
        if vertical {
            verticalDial
        } else {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(InCamTheme.ivory.opacity(0.48))
                Text(formatter(value))
                    .font(.system(size: vertical ? 14 : 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(InCamTheme.ivory)
            }
            Canvas { context, size in
                let length = vertical ? size.height : size.width
                let cross = vertical ? size.width : size.height
                let center = length / 2
                let count = Int(length / 20) + 1
                let phase = CGFloat((value / step).truncatingRemainder(dividingBy: 1)) * 10
                for index in -count...count {
                    let x = center + CGFloat(index) * 10 - phase
                    let height: CGFloat = index.isMultiple(of: 5) ? 14 : 8
                    let opacity = max(0.12, 0.55 * (1 - abs(x - center) / max(1, center)))
                    let tick = vertical ? CGRect(x: (cross - height) / 2, y: x, width: height, height: 1)
                                        : CGRect(x: x, y: (cross - height) / 2, width: 1, height: height)
                    context.fill(Path(tick),
                                 with: .color(.white.opacity(opacity)))
                }
                let marker = vertical ? CGRect(x: (cross - 24) / 2, y: center - 1, width: 24, height: 2)
                                      : CGRect(x: center - 1, y: (cross - 24) / 2, width: 2, height: 24)
                context.fill(Path(roundedRect: marker, cornerRadius: 1),
                             with: .color(InCamTheme.ivory))
            }
            .frame(height: vertical ? 112 : 44)
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { gesture in
                        if gestureStart == nil { gestureStart = value }
                        guard let gestureStart else { return }
                        let delta = Double(vertical ? gesture.translation.height : gesture.translation.width) / 12 * step
                        let raw = gestureStart + delta
                        value = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
                    }
                    .onEnded { _ in gestureStart = nil }
            )
            .accessibilityHint(vertical ? "Pull down for higher values or up for lower values" : "Swipe left or right to adjust")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Adjustment ruler")
            .accessibilityIdentifier(accessibilityID)
            .accessibilityValue(formatter(value))
            .accessibilityAdjustableAction { direction in
                value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
            }
        }
        }
    }

    private var verticalDial: some View {
        ZStack {
            Canvas { context, size in
                for mark in VerticalRulerMarks.layout(value: dragDisplayValue ?? value, step: step,
                                                     height: size.height, showsValue: showsValue) {
                    let width: CGFloat = mark.major ? 22 : 12
                    let tick = CGRect(x: (size.width - width) / 2, y: mark.y, width: width, height: 1)
                    context.fill(Path(roundedRect: tick, cornerRadius: 0.5),
                                 with: .color(tickColor?(min(1, max(0, 1 - Double(mark.y / size.height)))) ?? InCamTheme.ivory.opacity(mark.opacity)))
                }
            }
            if showsValue {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(formatter(value)).font(.system(size: valueFontSize, weight: .semibold, design: .rounded))
                    if let unit { Text(unit).font(.system(size: valueFontSize * 0.55, weight: .medium)) }
                }
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(InCamTheme.ivory)
                .padding(.horizontal, 4)
            } else {
                Capsule().fill(InCamTheme.ivory).frame(width: 24, height: 2)
            }
        }
        .frame(height: heightOverride ?? verticalHeight)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { gesture in
                if gestureStart == nil { gestureStart = value }
                guard let gestureStart else { return }
                let raw = gestureStart + Double(gesture.translation.height) / 9 * step
                dragDisplayValue = min(range.upperBound, max(range.lowerBound, raw))
                value = min(range.upperBound, max(range.lowerBound, (raw / step).rounded() * step))
            }
            .onEnded { _ in gestureStart = nil; dragDisplayValue = nil })
        .onDisappear { gestureStart = nil; dragDisplayValue = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Adjustment dial")
        .accessibilityIdentifier(accessibilityID)
        .accessibilityValue(formatter(value))
        .accessibilityHint("Pull down to increase or up to decrease")
        .accessibilityAdjustableAction { direction in
            value = min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step)))
        }
    }
}

/// Keep the readout window fixed while the scale moves behind it.
enum VerticalRulerMarks {
    struct Mark {
        let y: CGFloat
        let major: Bool
        let opacity: Double
    }

    static func layout(value: Double, step: Double, height: CGFloat, showsValue: Bool) -> [Mark] {
        guard value.isFinite, step > 0, height > 0 else { return [] }
        let position = value / step
        let whole = floor(position)
        let fraction = CGFloat(position - whole)
        let spacing: CGFloat = 9
        let center = height / 2
        let count = Int(ceil(height / spacing)) + 1
        return (-count...count).compactMap { index in
            let y = center + (CGFloat(index) + fraction) * spacing
            // Mask in screen coordinates, not tick indices: no drifting gap or text collisions.
            guard y >= 2, y <= height - 2, !showsValue || abs(y - center) >= 21 else { return nil }
            let major = (whole - Double(index)).truncatingRemainder(dividingBy: 4) == 0
            let edgeFade = min(1, min(y, height - y) / 16)
            return Mark(y: y, major: major, opacity: (major ? 0.65 : 0.4) * Double(edgeFade))
        }
    }
}
