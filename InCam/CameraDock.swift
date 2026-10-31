import SwiftUI

struct FocusControls: View {
    @EnvironmentObject private var camera: CameraController
    var vertical = false
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: vertical ? 5 : 12) {
            Text("FOCUS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.yellow)
            if vertical {
                Text("FAR").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                PrecisionRuler(value: Binding(get: { Double(camera.focusPosition) }, set: { camera.setFocus(auto: false, position: Float($0)) }), range: 0...1, step: 0.02, verticalHeight: 104, showsValue: false) { value in value < 0.1 ? "Near" : (value > 0.9 ? "Far" : "Manual focus") }
                    .environment(\.verticalCameraRuler, true)
                Text("NEAR").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            if vertical {
                Button { camera.setFocus(auto: true) } label: {
                    Text("Auto").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(camera.focusAuto ? .yellow : InCamTheme.ivory.opacity(0.5))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.accessibilityLabel("Enable autofocus")
            } else {
            HStack(spacing: 0) {
                ForEach([true, false], id: \.self) { auto in
                    Button { camera.setFocus(auto: auto) } label: {
                        Text(auto ? "AF" : "MF").frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(camera.focusAuto == auto ? .yellow : InCamTheme.ivory.opacity(0.4))
                    }
                }
            }
            }
            if !camera.focusAuto && !vertical {
                Slider(value: Binding(get: { Double(camera.focusPosition) }, set: { camera.setFocus(auto: false, position: Float($0)) }), in: 0...1)
                    .accessibilityLabel("Manual focus position")
                Text("Near ↔ Far").font(.caption)
            }
        }.font(.system(size: 12, weight: .semibold))
        .padding(vertical ? 8 : 12)
        .glass(in: vertical ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 18)), emphasized: true)
        .buttonStyle(PressScaleStyle())
        .accessibilityAction(.escape, onClose)
    }
}

/// Category swipes and value drags have separate touch areas.
struct CameraDock: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var colors: CameraColorStore
    @EnvironmentObject private var preferences: CameraScreenPreferences
    @Binding var expanded: DockItem?
    @Binding var page: CameraControlPage
    var showsPanel = true
    var floating = false
    var thumb = false
    var rail = false

    var body: some View {
        VStack(spacing: 0) {
            if showsPanel, expanded != nil {
                if rail { railInspector } else {
                inspector
                }
            } else {
                Button {
                    expanded = page.dockItem
                } label: {
                    Label("Controls", systemImage: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("controls.open")
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            if !rail {
                Color.clear.glass(in: RoundedRectangle(cornerRadius: floating ? 0 : 18), emphasized: expanded != nil)
            }
        }
        .shadow(color: rail ? .black.opacity(0.8) : .clear, radius: 2, y: 1)
        .accessibilityAction(.escape) { expanded = nil }
        .onChange(of: expanded) { _, item in
            if let item, page.dockItem != item { page = CameraControlPage(item) }
        }
    }

    private var railInspector: some View {
        ZStack {
            if page == .shutter {
                Text(camera.shutterAngleMode ? "ANGLE" : "SHUTTER SPEED")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(InCamTheme.ivory.opacity(0.55))
                        .frame(width: 92, height: 28)
                .accessibilityLabel("Shutter display mode")
                .accessibilityValue(camera.shutterAngleMode ? "Angle" : "Speed")
                .accessibilityHint("Double-tap to switch between shutter speed and angle")
                .accessibilityIdentifier("controls.shutterMode")
                .simultaneousGesture(TapGesture(count: 2).onEnded { camera.toggleShutterAngleMode() })
                .offset(y: -78)
            } else {
            Text(page == .whiteBalance ? "WB" : page.title(for: camera.mode))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(InCamTheme.ivory)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 16).onEnded { value in
                    guard abs(value.translation.width) > 24, abs(value.translation.width) > abs(value.translation.height) else { return }
                    select(page.adjacent(forward: value.translation.width < 0))
                })
                .accessibilityIdentifier("controls.pageTitle")
                .accessibilityHint("Swipe left or right to change settings")
                .offset(y: -78)
            }
            adjustment.id(page).environment(\.cameraRulerHeight, 112).frame(height: 112)
                .minimumScaleFactor(0.65)
            if supportsAuto {
                        Button { if !isAuto(page) { toggleAuto() } } label: {
                            Text("Auto").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isAuto(page) ? .yellow : InCamTheme.ivory.opacity(0.5))
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityLabel("Enable automatic \(page.title(for: camera.mode))")
                        .offset(y: 80)
            }
        }.frame(height: 192).padding(.horizontal, 4).buttonStyle(.plain)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if supportsAuto {
                    HStack(spacing: 2) {
                        ForEach([false, true], id: \.self) { auto in
                            Button { if isAuto(page) != auto { toggleAuto() } } label: {
                                Text(auto ? "Auto" : "Manual")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(isAuto(page) == auto ? .yellow : InCamTheme.ivory.opacity(0.35))
                                    .frame(minWidth: 52, minHeight: 44)
                                    .background(isAuto(page) == auto ? Color.yellow.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .accessibilityLabel("Adjustment mode")
                    .accessibilityValue(isAuto(page) ? "Auto" : "Manual")
                    .accessibilityHint("Tap to switch between Manual and Auto")
                    .accessibilityIdentifier("controls.autoToggle")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 0) {
                Button { select(page.adjacent(forward: false)) } label: {
                    Image(systemName: "chevron.left").frame(width: 44, height: 40)
                }
                .disabled(page == .whiteBalance)
                .accessibilityLabel("Previous setting")
                Text(page.title(for: camera.mode))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 16).onEnded { value in
                        guard abs(value.translation.width) > 24,
                              abs(value.translation.width) > abs(value.translation.height) else { return }
                        select(page.adjacent(forward: value.translation.width < 0))
                    })
                    .simultaneousGesture(TapGesture(count: 2).onEnded(toggleAuto))
                    .accessibilityIdentifier("controls.pageTitle")
                    .accessibilityHint("Swipe left or right to switch settings")
                Button { select(page.adjacent(forward: true)) } label: {
                    Image(systemName: "chevron.right").frame(width: 44, height: 40)
                }
                .disabled(page == .zoom)
                .accessibilityLabel("Next setting")
            }
            if preferences.showQuickRow && !thumb {
                HStack(spacing: 3) {
                    ForEach([CameraControlPage.whiteBalance, .shutter, .iso, .cameraColor]) { item in
                        Button { select(item) } label: {
                            Text(item == .whiteBalance ? "WB" : (item == .cameraColor ? "CC" : item.title(for: camera.mode)))
                                .font(.system(size: 10, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(page.dockItem == item.dockItem ? .white.opacity(0.13) : .white.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                                .foregroundStyle(page.dockItem == item.dockItem ? .yellow : InCamTheme.ivory.opacity(0.7))
                        }
                        .accessibilityIdentifier("controls.quick.\(item.rawValue)")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            adjustment
                .id(page)
                .frame(height: thumb ? 148 : 76)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                // Allow the dial's own drag/tap handling to remain intact;
                // this observer recognizes a second tap without cancelling it.
                .simultaneousGesture(TapGesture(count: 2).onEnded(resetCurrentAdjustment))
        }
        .padding(.horizontal, 6)
        .buttonStyle(.plain)
    }

    private var supportsAuto: Bool {
        [.whiteBalance, .tint, .shutter, .iso].contains(page)
    }

    private func toggleAuto() {
        switch page {
        case .whiteBalance: camera.setWhiteBalanceAuto(!camera.whiteBalanceAuto)
        case .tint: camera.setTintAuto(!camera.tintAuto)
        case .shutter: camera.setShutterAuto(!camera.shutterAuto)
        case .iso: camera.setISOAuto(!camera.isoAuto)
        default: break
        }
    }

    /// Double-tapping a dial restores its predictable shooting baseline.
    /// Auto is a separate explicit one-tap choice, so resetting a manual
    /// shutter or ISO never silently turns on automatic exposure.
    private func resetCurrentAdjustment() {
        switch page {
        case .whiteBalance:
            camera.setWhiteBalanceAuto(true)
        case .tint:
            camera.setTint(0)
        case .shutter:
            camera.toggleShutterAngleMode()
        case .iso:
            camera.setISO(100)
        default: break
        }
    }

    @ViewBuilder private var adjustment: some View {
        switch page {
        case .whiteBalance:
            PrecisionRuler(value: Binding(get: { Double(camera.temperature) }, set: {
                camera.setTemperature(Float($0))
            }), range: 2_000...10_000, step: 100) { "\(Int($0)) K" }
        case .tint:
            // Keep Tint nested under White Balance and expose the requested
            // Fuji-like -7...+7 scale, mapped to the device's native range.
            PrecisionRuler(value: Binding(get: { Double(camera.tint) / 12 }, set: {
                camera.setTint(Float($0 * 12))
            }), range: -7...7, step: 1) { String(format: "%+.0f", $0) }
        case .shutter:
            let options = shutterOptions
            // The rail readout and this ruler intentionally use the live
            // metered duration as their common source, including in Auto.
            // This prevents 1/40 on the readout while the dial says 1/60.
            let preferredSeconds = camera.exposureSeconds
            let dialIndex = options.indices.min(by: { abs(options[$0] - preferredSeconds) < abs(options[$1] - preferredSeconds) }) ?? 0
            let dialSeconds = options[dialIndex]
            PrecisionRuler(value: Binding(get: {
                Double(dialIndex)
            }, set: {
                camera.setExposure(options[min(options.count - 1, max(0, Int($0.rounded())))])
            }), range: 0...Double(options.count - 1), step: 1) { _ in
                camera.shutterAngleMode
                    ? String(format: "%.1f°", min(360, dialSeconds * Double(camera.frameRate) * 360))
                    : Self.shutterLabel(dialSeconds)
            }
        case .iso:
            let options = isoOptions
            PrecisionRuler(value: Binding(get: {
                Double(options.indices.min(by: { abs(options[$0] - Double(camera.iso)) < abs(options[$1] - Double(camera.iso)) }) ?? 0)
            }, set: {
                camera.setISO(Float(options[min(options.count - 1, max(0, Int($0.rounded()))) ]))
            }), range: 0...Double(options.count - 1), step: 1) { _ in
                Self.isoLabel(camera.iso)
            }
        case .rateOrFormat:
            if camera.mode == .video {
                PrecisionRuler(value: Binding(get: {
                    Double(fpsOptions.firstIndex(of: camera.frameRate) ?? 0)
                }, set: {
                    let index = min(fpsOptions.count - 1, max(0, Int($0.rounded())))
                    camera.setFrameRate(fpsOptions[index])
                }), range: 0...Double(max(0, fpsOptions.count - 1)), step: 1) {
                    "\(fpsOptions[min(fpsOptions.count - 1, max(0, Int($0.rounded())))]) FPS"
                }
                .disabled(camera.isRecording)
            } else {
                Picker("Photo format", selection: Binding(get: { camera.photoFormat }, set: { camera.setPhotoFormat($0) })) {
                    ForEach(camera.capabilities.photoFormats, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
            }
        case .cameraColor:
            CameraColorPicker()
        case .zoom:
            RampZoomControl()
        }
    }

    private var shutterOptions: [Double] {
        let range = camera.capabilities.manualExposureRange
        let fps = Double(max(1, camera.frameRate))
        let candidates: [Double] = camera.shutterAngleMode
            ? CameraExposureDefaults.shutterAngleDegrees.map { $0 / (fps * 360) }
            : CameraExposureDefaults.shutterSeconds
        let available = candidates.filter { $0 >= range.lowerBound - 0.0000001 && $0 <= range.upperBound + 0.0000001 }
        // Unusual hardware formats may support none of the usual presets.
        return available.isEmpty ? [range.lowerBound] : available
    }

    /// Exact ISO stops requested for the camera UI. This is intentionally a
    /// discrete list—not a linear ruler—then filtered by the active lens.
    private var isoOptions: [Double] {
        let requested: [Double] = [
            100, 125, 160, 200, 250, 320, 400, 500, 640,
            800, 1_000, 1_250, 1_600, 2_000, 2_500, 3_200,
            4_000, 5_000, 6_400, 8_000
        ]
        let range = camera.capabilities.manualISORange
        let supported = requested.filter { $0 >= range.lowerBound && $0 <= range.upperBound }
        return supported.isEmpty ? [max(100, (range.lowerBound / 100).rounded(.up) * 100)] : supported
    }

    private var fpsOptions: [Int] {
        camera.capabilities.frameRates.isEmpty ? [30] : camera.capabilities.frameRates
    }

    private func select(_ selection: CameraControlPage) {
        page = selection
        expanded = selection.dockItem
    }
    private func isAuto(_ page: CameraControlPage) -> Bool {
        switch page {
        case .whiteBalance: return camera.whiteBalanceAuto
        case .tint: return camera.tintAuto
        case .shutter: return camera.shutterAuto
        case .iso: return camera.isoAuto
        default: return false
        }
    }
    private func value(for item: DockItem) -> String {
        switch item {
        case .whiteBalance: return "\(Int(camera.temperature)) K"
        case .rateOrFormat: return camera.mode == .video ? "\(camera.frameRate)" : camera.photoFormat
        case .shutter: return Self.shutterLabel(camera.exposureSeconds)
        case .iso: return "\(Int(camera.iso.rounded()))"
        case .cameraColor: return colors.selectedSlot.map { colors.slots[$0].name } ?? "OFF"
        case .zoom: return String(format: "%.1f×", camera.zoom)
        }
    }
    private static func shutterLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return seconds >= 1 ? "\(Int(seconds.rounded()))\"" : "1/\(Int(min(100_000, 1 / seconds).rounded()))"
    }

    private static func isoLabel(_ iso: Float) -> String {
        String(format: "%d", Int(iso.rounded()))
    }
}

/// A single continuous touch owns expansion, zooming and collapse.
/// Its fixed outer frame and global drag coordinates prevent expansion from moving the gesture origin.
struct TouchZoomControl: View {
    @EnvironmentObject private var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var touching = false
    @State private var startZoom: CGFloat?
    @State private var displacement: CGFloat = 0
    var compact = false
    let onBegin: () -> Void

    var body: some View {
        ZStack {
            if touching && !compact {
                VStack {
                    Image(systemName: "plus")
                    Spacer()
                    Image(systemName: "minus")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.vertical, 16)
                Canvas { context, size in
                    for index in 0...16 where abs(index - 8) > 2 {
                        let y = 32 + CGFloat(index) * (size.height - 64) / 16
                        let width: CGFloat = index.isMultiple(of: 4) ? 20 : 10
                        context.fill(Path(CGRect(x: (size.width - width) / 2, y: y, width: width, height: 1)),
                                     with: .color(.white.opacity(0.35)))
                    }
                    let y = size.height / 2 - displacement * 58
                    context.fill(Path(roundedRect: CGRect(x: 5, y: y - 2, width: 4, height: 4), cornerRadius: 2),
                                 with: .color(.yellow))
                }
            }
            if compact && !touching {
                VStack(spacing: 2) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                    Text(String(format: "%.1f×", camera.zoom))
                        .font(.system(size: 9, weight: .medium)).monospacedDigit()
                }
            } else {
                Text(String(format: "%.1f×", camera.zoom))
                .font(.system(size: compact ? 13 : (touching ? 22 : 12), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(touching ? .yellow : InCamTheme.ivory)
                .minimumScaleFactor(0.7).lineLimit(1)
                .padding(.horizontal, 5)
            }
        }
        .frame(width: compact ? 44 : 60, height: compact ? 44 : (touching ? 164 : 40))
        .glass(in: Capsule(), emphasized: touching)
        .padding(.vertical, compact || touching ? 0 : 2)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($touching) { _, active, _ in active = true }
            .onChanged { gesture in
                if startZoom == nil { startZoom = camera.zoom; onBegin() }
                displacement = min(1, max(-1, -gesture.translation.height / 70))
                camera.setZoomVelocity(Double(displacement))
            }
            .onEnded { _ in stop() })
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: touching)
        .frame(width: compact ? 44 : 60, height: compact ? 44 : 164)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touch zoom")
        .accessibilityValue(String(format: "%.1f×", camera.zoom))
        .accessibilityIdentifier("zoom.touch")
        .accessibilityHint("Touch and slide up to zoom in or down to zoom out. You can drag past Record without pressing it. Release to stop zooming.")
        .accessibilityAdjustableAction { direction in camera.setZoom(camera.zoom + (direction == .increment ? 0.1 : -0.1)) }
        .onChange(of: touching) { _, active in if !active { stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onDisappear { stop() }
    }

    private func stop() {
        camera.stopZoomRamp()
        startZoom = nil
        displacement = 0
    }
}

/// A dedicated vertical camcorder rocker, independent of the horizontal value rulers.
struct VerticalZoomPanel: View {
    let onClose: () -> Void
    @EnvironmentObject private var camera: CameraController

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                Text("Zoom")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityIdentifier("controls.pageTitle")
            }
            RampZoomControl()
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
        .frame(width: 96)
        .glass(in: RoundedRectangle(cornerRadius: 24), emphasized: true)
        .buttonStyle(.plain)
    }
}

struct RampZoomControl: View {
    @EnvironmentObject private var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @State private var displacement: CGFloat = 0
    @GestureState private var dragging = false

    var body: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f×", camera.zoom))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(.yellow)
                .accessibilityIdentifier("zoom.value")
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)

            GeometryReader { proxy in
                let half = max(1, proxy.size.height / 2 - 12)
                Canvas { context, size in
                    for index in 0...20 {
                        let y = 10 + (size.height - 20) * CGFloat(index) / 20
                        let width: CGFloat = index.isMultiple(of: 5) ? 18 : 10
                        context.fill(Path(CGRect(x: (size.width - width) / 2, y: y, width: width, height: 1)),
                                     with: .color(.white.opacity(index == 10 ? 0.65 : 0.3)))
                    }
                    context.fill(Path(roundedRect: CGRect(x: size.width / 2 - 15,
                                                          y: size.height / 2 - displacement * half - 1.5,
                                                          width: 30, height: 3), cornerRadius: 1),
                                 with: .color(.yellow))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { value in
                        displacement = min(1, max(-1, -value.translation.height / half))
                        camera.setZoomVelocity(Double(displacement))
                    }
                    .onEnded { _ in stop() })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Vertical ramp zoom")
                .accessibilityIdentifier("zoom.rocker")
                .accessibilityValue(String(format: "%.1f times", camera.zoom))
                .accessibilityHint("Hold and slide up to zoom in, down to zoom out. Move farther for faster zoom. Release to stop.")
                .accessibilityAdjustableAction { direction in camera.setZoom(camera.zoom + (direction == .increment ? 0.1 : -0.1)) }
            }.frame(width: 60, height: 112)

            Image(systemName: "minus").font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text("Hold & slide").font(.system(size: 9, weight: .medium))
        }
        .onChange(of: dragging) { _, active in if !active { stop() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onDisappear { stop() }
    }

    private func stop() {
        camera.stopZoomRamp()
        withAnimation(.easeOut(duration: 0.15)) { displacement = 0 }
    }
}

private struct CameraColorPicker: View {
    @EnvironmentObject private var colors: CameraColorStore

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(Array(colors.slots.enumerated()), id: \.element.id) { index, recipe in
                        Button { colors.selectedSlot = index } label: {
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(previewGradient(for: index))
                                    .frame(width: 62, height: 50)
                                    .overlay {
                                        if colors.selectedSlot == index {
                                            RoundedRectangle(cornerRadius: 8).stroke(InCamTheme.ivory, lineWidth: 2)
                                            Image(systemName: "checkmark").font(.caption.bold())
                                        }
                                    }
                                Text(recipe.name)
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .foregroundStyle(InCamTheme.ivory)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                .padding(.trailing, 34)
            }
            Button { colors.selectedSlot = nil } label: {
                Image(systemName: "circle.slash")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(colors.selectedSlot == nil ? InCamTheme.ivory : InCamTheme.ivory.opacity(0.58))
                    .frame(width: 30, height: 30)
                    .glass(in: Circle(), emphasized: colors.selectedSlot == nil)
            }
            .accessibilityLabel("No Camera Color")
        }
        .padding(.top, 8)
    }

    private func previewGradient(for index: Int) -> LinearGradient {
        let pairs: [[Color]] = [
            [.gray, .black], [.brown, .black], [.orange, .brown], [.cyan, .black],
            [.gray.opacity(0.8), .brown], [.yellow, .brown], [.white, .black],
        ]
        return LinearGradient(colors: pairs[index % pairs.count], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
