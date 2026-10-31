import SwiftUI

enum ShortcutSide: Hashable {
    case leading
    case trailing
}

/// Four connected sectors spanning 135° around each thumb control.
struct ShortcutArc: View {
    let side: HorizontalAlignment
    let name: String
    let actions: [ShortcutAction]
    @Binding var openSide: ShortcutSide?
    let onSelect: (ShortcutAction, Int, ShortcutSide) -> Void

    @State private var selected: Int?

    private let canvasWidth: CGFloat = 260
    private let canvasHeight: CGFloat = 300
    private let buttonSize: CGFloat = 48
    private let innerRadius: CGFloat = 38
    private let outerRadius: CGFloat = 110
    private let centerY: CGFloat = 237

    private var identity: ShortcutSide { side == .leading ? .leading : .trailing }
    private var open: Bool { openSide == identity }
    private var assignedActions: [(offset: Int, element: ShortcutAction)] {
        Array(actions.prefix(4).enumerated()).filter { $0.element != .unassigned }
    }

    var body: some View {
        ZStack {
            if open {
                connectedSectors
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Text(buttonTitle)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.58)
                .padding(4)
                .foregroundStyle(InCamTheme.ivory)
                .frame(width: buttonSize, height: buttonSize)
                .glass(in: Circle(), emphasized: open)
                .overlay(alignment: side == .leading ? .topTrailing : .topLeading) {
                    Image(systemName: "circle.grid.2x2.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(InCamTheme.ivory.opacity(0.72))
                        .offset(x: side == .leading ? 2 : -2, y: -2)
                }
                .contentShape(Circle())
                .position(x: centerX, y: centerY)
                .onTapGesture {
                    if assignedActions.count == 1, let assignment = assignedActions.first {
                        openSide = nil
                        onSelect(assignment.element, assignment.offset, identity)
                        return
                    }
                    guard !assignedActions.isEmpty else { return }
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                        openSide = open ? nil : identity
                    }
                }
                .gesture(shortcutGesture)
                .accessibilityLabel(side == .leading ? "Custom Button 1" : "Custom Button 2")
                .accessibilityHint("Hold, then slide into one of four assignments")

            if !open { centerCaption }
        }
        .frame(width: canvasWidth, height: canvasHeight)
    }

    private var connectedSectors: some View {
        ZStack {
            ForEach(Array(assignedActions.enumerated()), id: \.element.offset) { position, assignment in
                let angles = angleRange(for: position, count: assignedActions.count)
                ZStack {
                    ThumbSectorShape(
                        center: CGPoint(x: centerX, y: centerY),
                        startDegrees: angles.lowerBound,
                        endDegrees: angles.upperBound,
                        innerRadius: innerRadius,
                        outerRadius: outerRadius)
                        .fill(selected == position ? InCamTheme.ivory : InCamTheme.graphite.opacity(0.9))
                        .overlay {
                            ThumbSectorShape(
                                center: CGPoint(x: centerX, y: centerY),
                                startDegrees: angles.lowerBound,
                                endDegrees: angles.upperBound,
                                innerRadius: innerRadius,
                                outerRadius: outerRadius)
                                .stroke(.white.opacity(selected == position ? 0.78 : 0.18), lineWidth: 0.9)
                        }
                        .contentShape(
                            ThumbSectorShape(
                                center: CGPoint(x: centerX, y: centerY),
                                startDegrees: angles.lowerBound,
                                endDegrees: angles.upperBound,
                                innerRadius: innerRadius,
                                outerRadius: outerRadius))
                        .onTapGesture {
                            choose(assignment.element, sourceIndex: assignment.offset)
                        }

                    leaderLine(position: position)
                        .allowsHitTesting(false)

                    actionButton(
                        assignment.element,
                        position: position,
                        sourceIndex: assignment.offset)
                }
            }
        }
        .frame(width: canvasWidth, height: canvasHeight)
    }

    private var centerCaption: some View {
        ZStack {
            Path { path in
                let direction: CGFloat = side == .leading ? 1 : -1
                path.move(to: CGPoint(x: centerX + direction * 27, y: centerY))
                path.addLine(to: CGPoint(x: centerX + direction * 47, y: centerY))
            }
            .stroke(InCamTheme.ivory.opacity(0.55), lineWidth: 1)

            Text(caption)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(InCamTheme.ivory.opacity(0.86))
                .lineLimit(1)
                .frame(width: 104, alignment: side == .leading ? .leading : .trailing)
                .position(x: centerX + (side == .leading ? 101 : -101), y: centerY)
        }
        .allowsHitTesting(false)
    }

    private var caption: String {
        if assignedActions.count == 1, let action = assignedActions.first?.element {
            return displayTitle(action)
        }
        if assignedActions.count > 1 { return name.isEmpty ? defaultName : name }
        return defaultName
    }

    private var buttonTitle: String {
        if assignedActions.count == 1, let action = assignedActions.first?.element {
            return compactTitle(action)
        }
        return assignedActions.count > 1 ? (name.isEmpty ? defaultShortName : name) : defaultShortName
    }

    private var defaultName: String { side == .leading ? "Custom Button 1" : "Custom Button 2" }
    private var defaultShortName: String { side == .leading ? "C1" : "C2" }

    private func leaderLine(position: Int) -> some View {
        let middle = middleAngle(for: position, count: assignedActions.count) * .pi / 180
        let lineStart = outerRadius - 3
        let lineEnd = outerRadius + 18
        return Path { path in
            path.move(to: CGPoint(
                x: centerX + cos(middle) * lineStart,
                y: centerY + sin(middle) * lineStart))
            path.addLine(to: CGPoint(
                x: centerX + cos(middle) * lineEnd,
                y: centerY + sin(middle) * lineEnd))
        }
        .stroke(selected == position ? InCamTheme.ivory : InCamTheme.ivory.opacity(0.5),
                lineWidth: selected == position ? 1.5 : 1)
    }

    private func actionButton(
        _ action: ShortcutAction,
        position: Int,
        sourceIndex: Int
    ) -> some View {
        let middle = middleAngle(for: position, count: assignedActions.count) * .pi / 180
        let labelRadius = outerRadius + 38
        return Button {
            choose(action, sourceIndex: sourceIndex)
        } label: {
            Text(displayTitle(action))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .foregroundStyle(InCamTheme.ivory)
                .padding(.horizontal, 5)
                .frame(width: 92, height: 34)
                .background(InCamTheme.graphite.opacity(0.76), in: Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .position(
            x: centerX + cos(middle) * labelRadius,
            y: centerY + sin(middle) * labelRadius)
    }

    private func choose(_ action: ShortcutAction, sourceIndex: Int) {
        onSelect(action, sourceIndex, identity)
        withAnimation(.easeOut(duration: 0.16)) { openSide = nil }
    }

    private func displayTitle(_ action: ShortcutAction) -> String {
        switch action {
        case .unassigned: return "Unassigned"
        case .aspectRatio: return "Aspect Ratio"
        case .whiteBalance: return "White Balance"
        case .exposureCompensation: return "Exposure"
        case .cameraColor: return "Camera Color"
        default: return action.rawValue
        }
    }

    private func compactTitle(_ action: ShortcutAction) -> String {
        switch action {
        case .aspectRatio: return "Aspect"
        case .whiteBalance: return "WB"
        case .cameraColor: return "Color"
        case .exposureCompensation: return "EV"
        case .level: return "Level"
        default: return action.rawValue
        }
    }

    private var shortcutGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.26)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard !assignedActions.isEmpty else { return }
                switch value {
                case .first(true):
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { openSide = identity }
                case .second(true, let drag):
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) { openSide = identity }
                    if let drag { selected = sector(for: drag.translation) }
                default: break
                }
            }
            .onEnded { _ in
                if let selected, assignedActions.indices.contains(selected) {
                    let assignment = assignedActions[selected]
                    onSelect(assignment.element, assignment.offset, identity)
                }
                selected = nil
            }
    }

    private var centerX: CGFloat { side == .leading ? 42 : canvasWidth - 42 }

    private func angleRange(for index: Int, count: Int) -> ClosedRange<Double> {
        let width = 135.0 / Double(max(1, count))
        if side == .leading {
            return (-100 + Double(index) * width)...(-100 + Double(index + 1) * width)
        }
        return (-80 - Double(index + 1) * width)...(-80 - Double(index) * width)
    }

    private func middleAngle(for index: Int, count: Int) -> CGFloat {
        let range = angleRange(for: index, count: count)
        return CGFloat((range.lowerBound + range.upperBound) / 2)
    }

    private func sector(for translation: CGSize) -> Int? {
        let count = assignedActions.count
        guard count > 0 else { return nil }
        let radius = hypot(translation.width, translation.height)
        guard radius >= innerRadius - 8 else { return nil }
        var angle = atan2(translation.height, translation.width) * 180 / .pi
        if side == .trailing, angle > 0 { angle -= 360 }
        if side == .leading {
            guard angle >= -110, angle <= 45 else { return nil }
            return min(count - 1, max(0, Int((angle + 100) / (135 / Double(count)))))
        }
        guard angle <= -70, angle >= -225 else { return nil }
        return min(count - 1, max(0, Int((-80 - angle) / (135 / Double(count)))))
    }
}

private struct ThumbSectorShape: Shape {
    let center: CGPoint
    let startDegrees: Double
    let endDegrees: Double
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let start = Angle(degrees: startDegrees)
        let end = Angle(degrees: endDegrees)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end,
                    clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start,
                    clockwise: true)
        path.closeSubpath()
        return path
    }
}
