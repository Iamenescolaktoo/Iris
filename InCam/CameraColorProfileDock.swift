import Foundation
import SwiftUI

// FILE GUIDE: The Custom Colors dock and full-page profile editor. Saved
// profile cards live only in the dock; editing always opens a dedicated page.

/// The dock starts as one wheel. Tapping it reveals saved Custom Color image
/// circles with an Add circle at the far right; it is never a large overlay.
struct CameraColorProfileLauncher: View {
    @EnvironmentObject private var colors: CameraColorStore
    @Binding var isDockExpanded: Bool
    let onAdd: () -> Void
    let onLoad: (Int) -> Void
    let onEdit: (Int) -> Void
    let onDelete: (Int) -> Void

    @State private var actionSlot: Int?

    private var savedSlots: [Int] {
        Array(colors.quickSlots.indices.prefix(5)).filter { colors.quickSlots[$0] != nil }
    }

    private var hasFreeSlot: Bool {
        colors.quickSlots.prefix(5).contains(where: { $0 == nil })
    }

    var body: some View {
        HStack(spacing: 8) {
            if isDockExpanded {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { isDockExpanded = false }
                } label: {
                    ColorWheelIcon()
                        .frame(width: 50, height: 50)
                        .glass(in: Circle(), emphasized: true)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Close Custom Colors dock")

                ForEach(savedSlots, id: \.self) { slot in
                    profileButton(slot)
                }
            }

            if isDockExpanded {
                if hasFreeSlot {
                    addButton
                }
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { isDockExpanded = true }
                } label: {
                    ColorWheelIcon()
                        .frame(width: 68, height: 68)
                        .glass(in: Circle(), emphasized: false)
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel("Custom Colors")
                .accessibilityHint("Shows saved Custom Color profiles")
            }
        }
        .confirmationDialog("Custom Color Profile", isPresented: Binding(
            get: { actionSlot != nil },
            set: { if !$0 { actionSlot = nil } }
        ), titleVisibility: .visible) {
            if let slot = actionSlot {
                Button("Edit CC\(slot + 1)") {
                    actionSlot = nil
                    onEdit(slot)
                }
                Button("Delete CC\(slot + 1)", role: .destructive) {
                    actionSlot = nil
                    onDelete(slot)
                }
            }
        }
        .accessibilityIdentifier("cameraColors.profileDock")
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .glass(in: Circle(), emphasized: true)
                .overlay { Circle().stroke(.white.opacity(0.92), lineWidth: 1.5) }
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Add Custom Color profile")
    }

    private func profileButton(_ slot: Int) -> some View {
        Button {
            onLoad(slot)
        } label: {
            Image("ColorCheckerReference")
                .resizable()
                .scaledToFill()
                .frame(width: 50, height: 50)
                .clipShape(Circle())
                .overlay { Circle().stroke(.white.opacity(0.88), lineWidth: 1.5) }
                .overlay(alignment: .bottom) {
                    Text("CC\(slot + 1)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.58), in: Capsule())
                        .padding(.bottom, 2)
                }
        }
        .buttonStyle(PressScaleStyle())
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.55).onEnded { _ in
            actionSlot = slot
        })
        .accessibilityLabel("Custom Color \(slot + 1)")
        .accessibilityHint("Tap to load. Hold for Edit or Delete.")
    }
}

/// Full-page editor: color-checker image at left and HSL controls at right.
/// A selected range is shown solely by its white-outlined circular swatch.
struct CameraColorProfileEditorPage: View {
    @EnvironmentObject private var colors: CameraColorStore
    @ObservedObject var controls: ColorDockControls
    let slot: Int
    @Binding var isPresented: Bool
    @Binding var isDockExpanded: Bool

    @State private var selectedBand: HSLBand = .red

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height

            Group {
                if landscape {
                    HStack(spacing: 24) {
                        referenceImage
                            .frame(width: proxy.size.width * 0.62)
                        inspector
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 18) {
                        referenceImage
                            .frame(height: proxy.size.height * 0.42)
                        inspector
                    }
                }
            }
            .padding(.horizontal, landscape ? 36 : 22)
            .padding(.vertical, 18)
            .overlay(alignment: .topLeading) { backButton }
            .overlay(alignment: .top) { title }
            .overlay(alignment: .topTrailing) { saveButton }
        }
        .background(InCamTheme.graphite.ignoresSafeArea())
        .foregroundStyle(InCamTheme.ivory)
        .accessibilityIdentifier("cameraColors.editorPage")
    }

    private var title: some View {
        Text("CUSTOM COLORS · CC\(slot + 1)")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .tracking(0.9)
            .padding(.top, 18)
    }

    private var backButton: some View {
        Button {
            isPresented = false
            isDockExpanded = true
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel("Back to Custom Color profiles")
    }

    private var saveButton: some View {
        Button("SAVE") {
            var saved = controls.recipe
            saved.name = "CC\(slot + 1)"
            colors.saveQuick(saved, to: slot)
            controls.loadedCustomSlot = slot
            isPresented = false
            // Returning to an expanded dock immediately exposes the new
            // thumbnail as well as the trailing Add circle.
            isDockExpanded = true
        }
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(.yellow)
        .buttonStyle(.plain)
        .padding(24)
        .accessibilityLabel("Save as Custom Color \(slot + 1)")
    }

    /// The user-selected color checker is bundled temporarily so the editor
    /// has a meaningful, visible target while import/capture stays deferred.
    private var referenceImage: some View {
        Image("ColorCheckerReference")
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityLabel("Color checker reference image")
    }

    private var inspector: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 18) {
                ColorComponentBar(title: "HUE", value: componentBinding(.hue), tint: hueGradient)
                ColorComponentBar(title: "SAT", value: componentBinding(.saturation), tint: saturationGradient)
                ColorComponentBar(title: "LUM", value: componentBinding(.luminance), tint: luminanceGradient)

                Text("Recipe settings are saved to CC\(slot + 1). They do not yet alter recorded video.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(InCamTheme.ivory.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Individual swatches remain vertically ordered on the right;
            // there is no redundant rainbow rail behind them.
            VerticalColorSwatches(selected: $selectedBand)
                .frame(width: 42)
        }
        .padding(.top, 46)
    }

    private func componentBinding(_ component: HSLComponent) -> Binding<Double> {
        Binding(
            get: {
                let adjustment = controls.recipe.hsl[selectedBand] ?? HSLAdjustment()
                switch component {
                case .hue: return adjustment.hue / 0.0125
                case .saturation: return adjustment.saturation / 0.025
                case .luminance: return adjustment.luminance / 0.025
                }
            },
            set: { displayedValue in
                var adjustment = controls.recipe.hsl[selectedBand] ?? HSLAdjustment()
                switch component {
                case .hue: adjustment.hue = displayedValue * 0.0125
                case .saturation: adjustment.saturation = displayedValue * 0.025
                case .luminance: adjustment.luminance = displayedValue * 0.025
                }
                controls.recipe.hsl[selectedBand] = adjustment
            }
        )
    }

    private var hueGradient: LinearGradient {
        LinearGradient(colors: [.pink, .purple, .blue, .cyan, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
    }

    private var saturationGradient: LinearGradient {
        LinearGradient(colors: [.gray, selectedBand.color], startPoint: .leading, endPoint: .trailing)
    }

    private var luminanceGradient: LinearGradient {
        LinearGradient(colors: [.black, selectedBand.color, .white], startPoint: .leading, endPoint: .trailing)
    }
}

private enum HSLComponent { case hue, saturation, luminance }

/// One direct manipulation bar. Its label is on the left of—not above—the
/// bar, and each H/S/L bar remains visible while another is being changed.
private struct ColorComponentBar: View {
    let title: String
    @Binding var value: Double
    let tint: LinearGradient
    @State private var dragStartValue: Double?

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(InCamTheme.ivory.opacity(0.94))
                .frame(width: 34, alignment: .leading)

            GeometryReader { geometry in
                let normalized = (value + 7) / 14
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.12)).frame(height: 10)
                    Capsule().fill(tint).frame(height: 10)
                    Circle()
                        .fill(.white)
                        .frame(width: 22, height: 22)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .offset(x: normalized * max(0, geometry.size.width - 22))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            if dragStartValue == nil { dragStartValue = value }
                            let delta = gesture.translation.width / max(1, geometry.size.width) * 14
                            value = min(7, max(-7, (dragStartValue ?? value) + delta))
                        }
                        .onEnded { _ in dragStartValue = nil }
                )
            }
            .frame(height: 26)

            Text(String(format: "%+.0f", value))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(InCamTheme.ivory.opacity(0.94))
                .frame(width: 27, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) adjustment")
        .accessibilityValue(String(format: "%+.0f", value))
        .accessibilityHint("Drag left or right to adjust")
    }
}

/// The selected HSL range is represented only by its white circle outline.
/// Removing the old side gradient keeps the selected hue unambiguous.
private struct VerticalColorSwatches: View {
    @Binding var selected: HSLBand

    var body: some View {
        VStack(spacing: 7) {
            ForEach(HSLBand.allCases) { band in
                Button {
                    selected = band
                } label: {
                    Circle()
                        .fill(band.color)
                        .overlay {
                            Circle().stroke(.white, lineWidth: selected == band ? 3 : 0.8)
                        }
                        .frame(width: 31, height: 31)
                        .shadow(color: selected == band ? band.color.opacity(0.75) : .clear, radius: 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(band.rawValue.capitalized)
                .accessibilityValue(selected == band ? "Selected" : "")
            }
        }
        .accessibilityIdentifier("cameraColors.verticalSwatches")
    }
}

private struct ColorWheelIcon: View {
    var body: some View {
        Circle()
            .fill(AngularGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
                center: .center
            ))
            .padding(10)
            .overlay { Circle().stroke(.white.opacity(0.95), lineWidth: 1.5).padding(10) }
            .overlay { Circle().fill(InCamTheme.graphite).padding(20) }
    }
}
