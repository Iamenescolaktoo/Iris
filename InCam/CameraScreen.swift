import AVFoundation
import AVKit
import SwiftUI

struct CameraScreen: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var colors: CameraColorStore
    @EnvironmentObject private var shortcuts: ShortcutStore
    @EnvironmentObject private var preferences: CameraScreenPreferences
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var orientation = CameraOrientation.shared
    @AppStorage("incam.controls.layout") private var controlLayout = CameraControlLayout.floating
    @AppStorage("incam.capture.photoEnabled") private var photoEnabled = false
    @AppStorage("incam.composition.grid.mode") private var savedGridMode = GridMode.off.rawValue
    @AppStorage("incam.composition.grid.last-mode") private var savedLastGridMode = GridMode.thirds.rawValue
    @AppStorage("incam.composition.grid.density") private var savedGridDensity = 3
    @AppStorage("incam.composition.level.enabled") private var levelEnabled = false

    private var ratio: CompositionRatio { preferences.selectedRatio }
    @State private var grid = GridMode.off
    @State private var lastGrid = GridMode.thirds
    @State private var gridTurnedOffAt: Date?
    @State private var gridDensity = 3
    @State private var expandedDock: DockItem?
    @State private var controlPage = CameraControlPage.whiteBalance
    @State private var showSettings = false
    @State private var audioInspectorOpen = false
    @State private var showRatioRuler = false
    @State private var showRatioChoices = false
    @State private var showGridChoices = false
    @State private var showFormatChoices = false
    @State private var focusTarget: CGPoint?
    @State private var focusTargetDismissWorkItem: DispatchWorkItem?
    @State private var focusInspector = false
    @State private var focusInspectorDismissWorkItem: DispatchWorkItem?
    @State private var exposureInspector = false
    @State private var exposureTarget = CGPoint(x: 0.5, y: 0.5)
    @State private var exposureTargetPulse: CGFloat = 1
    @State private var colorDockExpanded = false
    @StateObject private var colorControls = ColorDockControls()
    @State private var showGallery = false
    @State private var openShortcutSide: ShortcutSide?
    @State private var shortcutAdjustment: ShortcutAdjustment?

    private var adjustmentExpanded: Bool { expandedDock != nil }

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            let colorDockHeight: CGFloat = portrait ? 0 : 44
            // Fixed width: an open tool must never push the live camera into
            // the charcoal control rectangle or move that rectangle itself.
            // This width is deliberately constant. Gallery, Record, and
            // Settings share its one vertical control column; the live camera
            // image must never move into this charcoal surface.
            let rightControls: CGFloat = 196
            let previewFrame = PreviewLayout.frame(in: proxy.size, ratio: ratio, portrait: portrait,
                                                  safeLeft: orientation.windowSafeAreaInsets.left,
                                                  safeRight: orientation.windowSafeAreaInsets.right,
                                                  adjustmentExpanded: adjustmentExpanded, rightControls: rightControls)
            // Reserve outside margins for the statistics/dial and capture controls.
            let leftInset = max(12, orientation.windowSafeAreaInsets.left)
            // The color dock belongs to the live camera rectangle, not to the
            // full phone. The remaining trailing width is for thumb controls.
            let cameraRight = max(1, proxy.size.width - rightControls)
            let captureCenter = CGPoint(x: cameraRight + rightControls / 2, y: proxy.size.height / 2)
            // Recording feedback uses the selected composition frame. With
            // framing removed, it traces the actual device container instead
            // of inventing a generic rectangle in the middle of the screen.
            let cameraViewport = CGRect(x: 0, y: 0, width: cameraRight, height: proxy.size.height)
            let recordingRatioAspect = portrait ? 1 / ratio.value : ratio.value
            let recordingRatioWidth = min(cameraViewport.width, cameraViewport.height * recordingRatioAspect)
            let recordingRatioFrame = CGRect(
                x: cameraViewport.midX - recordingRatioWidth / 2,
                y: cameraViewport.midY - recordingRatioWidth / recordingRatioAspect / 2,
                width: recordingRatioWidth,
                height: recordingRatioWidth / recordingRatioAspect
            )
            // The dock and left composition-tool stack follow the selected
            // guide, not the physical phone center. A narrower 4:3 or 1:1
            // guide therefore carries its own controls inward with it.
            let activeGuideFrame = preferences.framingGuide ? recordingRatioFrame : cameraViewport
            // A rounded rectangle rather than a capsule, deliberately 13%
            // shorter than the available guide. Its width is recalculated
            // whenever the selected aspect ratio changes.
            let dockWidth = min(520, activeGuideFrame.width * 0.72)
            // 16:9 is shown as a true edge-to-edge preview crop: the camera
            // image fills the whole rounded viewport, with no blurred guide
            // bands or leftover edges. This changes preview only, not output.
            let viewportAspect = cameraRight / max(1, proxy.size.height)
            let ratioPreviewZoom: CGFloat = !portrait && ratio == .sixteenNine
                ? max(1, ratio.value / viewportAspect) : 1
            ZStack {
                // Outside the live camera viewport: a muted, dock-like control surface.
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        LinearGradient(colors: [.white.opacity(0.20), .white.opacity(0.06), InCamTheme.graphite.opacity(0.38), .black.opacity(0.16)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }
                    .frame(width: max(0, proxy.size.width - cameraRight), height: proxy.size.height)
                    .position(x: (cameraRight + proxy.size.width) / 2, y: proxy.size.height / 2)
                    .allowsHitTesting(false)
                viewfinder
                    .scaleEffect(ratioPreviewZoom)
                    .frame(width: cameraRight, height: proxy.size.height)
                    .overlay {
                        if camera.exposureLocked {
                            // AE is a direct target gesture, not a second
                            // numeric ruler. Up/right raises it; down/left lowers it.
                            let targetSize = 44 * exposureTargetPulse
                            let halfSize = targetSize / 2
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.yellow, lineWidth: 1.5)
                                .frame(width: targetSize, height: targetSize)
                                .contentShape(Rectangle())
                                .position(x: min(cameraRight - halfSize, max(halfSize, exposureTarget.x * cameraRight)),
                                          y: min(proxy.size.height - halfSize, max(halfSize, exposureTarget.y * proxy.size.height)))
                                .gesture(DragGesture(minimumDistance: 12)
                                    .onChanged { drag in
                                        let horizontal = drag.translation.width
                                        let vertical = drag.translation.height
                                        let primary = abs(horizontal) >= abs(vertical) ? horizontal : -vertical
                                        // Size follows the live gesture: upward/rightward travel
                                        // grows towards 1.5×, while downward/leftward travel
                                        // contracts towards 0.8×. It returns to neutral on release.
                                        let travel = min(1, abs(primary) / 96)
                                        let scale = primary >= 0 ? 1 + 0.5 * travel : 1 - 0.2 * travel
                                        withAnimation(.interactiveSpring(response: 0.16, dampingFraction: 0.82)) {
                                            exposureTargetPulse = scale
                                        }
                                    }
                                    .onEnded { drag in
                                        let horizontal = drag.translation.width
                                        let vertical = drag.translation.height
                                        guard max(abs(horizontal), abs(vertical)) >= 18 else {
                                            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { exposureTargetPulse = 1 }
                                            return
                                        }
                                        let increase = abs(horizontal) >= abs(vertical)
                                            ? horizontal > 0 : vertical < 0
                                        adjustExposureTarget(increase: increase)
                                    })
                                .accessibilityLabel("Locked exposure target")
                                .accessibilityHint("Swipe up or right to raise exposure. Swipe down or left to lower exposure.")
                        } else if let target = focusTarget {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.yellow, lineWidth: 1.5)
                                .frame(width: 44, height: 44)
                                .position(x: min(cameraRight - 24, max(24, target.x * cameraRight)),
                                          y: min(proxy.size.height - 24, max(24, target.y * proxy.size.height)))
                                .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: portrait ? 0 : 22, style: .continuous))
                    .position(x: cameraRight / 2, y: proxy.size.height / 2)
                CompositionOverlay(safeLeft: orientation.windowSafeAreaInsets.left, safeRight: orientation.windowSafeAreaInsets.right,
                                   adjustmentExpanded: adjustmentExpanded, rightControls: rightControls,
                                   framingEnabled: preferences.framingGuide, ratio: ratio, grid: grid, gridDensity: gridDensity, levelEnabled: levelEnabled,
                                   roll: camera.levelRoll, pitch: camera.levelPitch, levelIsCentered: camera.levelIsCentered, isPortrait: portrait)
                    .animation(.spring(response: 0.34, dampingFraction: 0.9), value: ratio)

                if adjustmentExpanded || focusInspector || exposureInspector || colorDockExpanded || audioInspectorOpen || showGridChoices || showRatioChoices || showFormatChoices {
                    transientControlsDismissalLayer(cameraRight: cameraRight, height: proxy.size.height)
                }

                mainCameraOverlay(previewFrame: previewFrame, portrait: portrait, leftInset: leftInset)

                if audioInspectorOpen && !portrait {
                    CompactAudioInspector(onClose: { audioInspectorOpen = false })
                        // A separate column beside Audio: this never covers
                        // the fixed Audio / Grid / Format tool stack.
                        .position(x: leftInset + 174, y: previewFrame.minY + 65)
                        .zIndex(9)
                }

                elapsedReadout
                    .position(x: previewFrame.midX,
                              y: previewFrame.minY + (portrait ? max(24, orientation.windowSafeAreaInsets.top + 22) : 26))
                    .allowsHitTesting(false)
                    .zIndex(4)

                // The Grid icon opens two adjacent, one-value controls.
                // Tapping either advances it through Settings' saved order;
                // it never exposes a stack of every possible value.
                if !portrait && showGridChoices {
                    CompositionCyclingRow(ratio: ratio, grid: grid, levelEnabled: levelEnabled,
                                          cycleRatio: cycleRatio, cycleGrid: cycleGrid,
                                          toggleLevel: { levelEnabled.toggle() })
                        // The fixed Grid button is the second control in the
                        // left stack (audio is first). Start this three-cell
                        // row *after* that button, rather than on top of the
                        // audio row, so Ratio, Grid, and Level never overlap
                        // either the source button or each other.
                        // Align with the Grid button's own center (the
                        // middle item in the Audio / Grid / Format stack),
                        // never with the lower 4K/format button.
                        .position(x: leftInset + 178, y: previewFrame.minY + 68)
                        .zIndex(8)
                }

                if camera.exposureLocked {
                    Text("AE LOCK")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .frame(width: 64, height: 28)
                        .allowsHitTesting(false)
                    .position(x: previewFrame.midX, y: previewFrame.minY + 52)
                    .zIndex(5)
                }

                if !portrait {
                    modeToggle
                        .position(x: cameraRight + 28, y: 42)
                    settingsButton
                        // Settings, Record, and Gallery share one fixed
                        // vertical column through the grey control surface.
                        .position(x: captureCenter.x, y: 42)
                    if !camera.focusAuto {
                        // Manual-focus gestures live behind the right-hand
                        // controls. Empty mousepad taps return to the normal
                        // Record presentation; a vertical swipe reopens the
                        // ruler and adjusts focus even while recording. Its
                        // hit area begins below Settings, so Settings remains
                        // usable in MF instead of being covered by the pad.
                        Color.clear
                            .frame(width: rightControls, height: max(1, proxy.size.height - 96))
                            .contentShape(Rectangle())
                            .position(x: captureCenter.x, y: 96 + max(1, proxy.size.height - 96) / 2)
                            .onTapGesture {
                                cancelFocusInspectorDismissal()
                                focusInspector = false
                            }
                            .gesture(DragGesture(minimumDistance: 6)
                                .onChanged { drag in
                                    cancelFocusInspectorDismissal()
                                    focusInspector = true
                                    let position = Float(min(1, max(0, 1 - drag.location.y / max(1, proxy.size.height))))
                                    camera.setFocus(auto: false, position: position)
                                }
                                .onEnded { _ in scheduleFocusInspectorDismissal() })
                            .zIndex(3)
                    }
                    if !focusInspector && !adjustmentExpanded && !colorDockExpanded {
                        // The MF pad intentionally takes Record's place while
                        // its ruler is open. Tapping that pad closes the ruler
                        // and returns the normal Record control—no overlap.
                        LandscapeCaptureCluster(onZoomBegin: { dismissAdjustment(); colorDockExpanded = false })
                            .position(captureCenter)
                            .zIndex(4)
                    }
                    if focusInspector {
                        VStack(spacing: 5) {
                            Text("FOCUS").font(.system(size: 10, weight: .medium))
                            Text("FAR").font(.system(size: 9))
                            PrecisionRuler(value: Binding(get: { Double(camera.focusPosition) }, set: {
                                cancelFocusInspectorDismissal()
                                camera.setFocus(auto: false, position: Float($0))
                            }), range: 0...1, step: 0.02, verticalHeight: 112, showsValue: false) { _ in "Manual focus" }
                                .environment(\.verticalCameraRuler, true)
                                .accessibilityIdentifier("focus.manualRuler")
                                .simultaneousGesture(DragGesture(minimumDistance: 0)
                                    .onChanged { _ in cancelFocusInspectorDismissal() }
                                    .onEnded { _ in scheduleFocusInspectorDismissal() })
                            Text("NEAR").font(.system(size: 9))
                        }
                        .frame(width: 64)
                        .foregroundStyle(InCamTheme.ivory)
                        .shadow(color: .black, radius: 3, y: 1)
                        .position(x: captureCenter.x, y: captureCenter.y - 18)
                        .zIndex(5)
                    } else if colorDockExpanded {
                        RightColorAdjustment(controls: colorControls)
                            .position(captureCenter)
                            .zIndex(5)
                    }
                    // Gallery remains in the fixed right column beneath the
                    // Settings / Record column.
                    rightColumnUtilities
                        // Mirror Settings' 16-point outer padding at the
                        // bottom instead of giving Gallery an oversized gap.
                        .position(x: captureCenter.x, y: proxy.size.height - 42)
                        .zIndex(8)
                    // Center the dock in what the camera sees, never in the
                    // whole device window or the right-hand control surface.
                    let dockLeft = activeGuideFrame.midX - dockWidth / 2
                    let dockRight = dockLeft + dockWidth
                    CameraColorDock(controls: colorControls, expanded: $colorDockExpanded)
                        .frame(width: max(1, dockRight - dockLeft), height: colorDockHeight)
                        .position(x: (dockLeft + dockRight) / 2, y: proxy.size.height - 8 - colorDockHeight / 2)
                        .zIndex(6)
                }

                if expandedDock == .zoom {
                    VerticalZoomPanel { expandedDock = nil }
                        .position(x: portrait ? proxy.size.width - max(14, proxy.safeAreaInsets.trailing) - 48
                                              : leftInset + 146,
                                  y: proxy.size.height / 2)
                        .zIndex(5)
                } else if !portrait, expandedDock != nil {
                    CameraDock(expanded: $expandedDock, page: $controlPage, thumb: true, rail: true)
                        .environment(\.verticalCameraRuler, true)
                        .frame(width: 64)
                        // CAMERA's heading occupies 28 points above the three readouts.
                        .position(captureCenter)
                        .zIndex(5)
                } else if controlLayout == .floating, expandedDock != nil {
                    FloatingCameraControls(expanded: $expandedDock, page: $controlPage,
                                           viewport: proxy.size, safeArea: proxy.safeAreaInsets)
                        .zIndex(2)
                }
                // Recording is signalled by the timer and capture control.
                // There is intentionally no red perimeter around the image.
            }
            .background(.black)
            .background(CameraOrientationReader())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: adjustmentExpanded)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: colorDockExpanded)
        }
        .ignoresSafeArea()
        .foregroundStyle(InCamTheme.ivory)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .modifier(PhysicalCaptureEventModifier(
            enabled: scenePhase == .active && !showSettings && !showGallery,
            capture: { camera.capture() }
        ))
        .onAppear {
            if !photoEnabled && camera.mode == .photo && !camera.isRecording { camera.toggleMode() }
            camera.setCaptureRotation(orientation.rotationAngle)
            camera.setLevelInterfaceOrientation(orientation.interfaceOrientation)
            camera.setLevelMonitoringEnabled(levelEnabled)
            updateOutputFraming()
            updateCameraActivity()
            grid = GridMode(rawValue: savedGridMode) ?? .off
            lastGrid = GridMode(rawValue: savedLastGridMode) ?? .thirds
            gridDensity = min(6, max(2, savedGridDensity))
            camera.setCameraColorRecipe(colorControls.recipe)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--show-controls") { expandedDock = .whiteBalance }
            if ProcessInfo.processInfo.arguments.contains("--show-iso") { controlPage = .iso; expandedDock = .iso }
            if ProcessInfo.processInfo.arguments.contains("--show-shutter") { controlPage = .shutter; expandedDock = .shutter }
            if ProcessInfo.processInfo.arguments.contains("--show-zoom") { openZoom() }
            if ProcessInfo.processInfo.arguments.contains("--show-colors") { colorDockExpanded = true }
            if ProcessInfo.processInfo.arguments.contains("--show-saturation") { colorControls.selection = "Saturation"; colorDockExpanded = true }
            if ProcessInfo.processInfo.arguments.contains("--show-color-mix") { colorControls.selection = "Color Mix"; colorDockExpanded = true }
            if ProcessInfo.processInfo.arguments.contains("--show-exposure") { openExposure(at: CGPoint(x: 0.5, y: 0.5)) }
            if ProcessInfo.processInfo.arguments.contains("--show-exposure-right") { openExposure(at: CGPoint(x: 0.98, y: 0.5)) }
            if ProcessInfo.processInfo.arguments.contains("--show-grids") { showGridChoices = true; grid = .diagonals }
            #endif
        }
        .onChange(of: orientation.interfaceOrientation) { _, _ in
            focusTarget = nil
            showRatioChoices = false
            showFormatChoices = false
            camera.setCaptureRotation(orientation.rotationAngle)
            camera.setLevelInterfaceOrientation(orientation.interfaceOrientation)
            openShortcutSide = nil
            shortcutAdjustment = nil
        }
        .onChange(of: grid) { _, newValue in
            savedGridMode = newValue.rawValue
            if newValue != .off {
                lastGrid = newValue
                savedLastGridMode = newValue.rawValue
            }
        }
        .onChange(of: gridDensity) { _, newValue in savedGridDensity = min(6, max(2, newValue)) }
        .onChange(of: levelEnabled) { _, enabled in camera.setLevelMonitoringEnabled(enabled) }
        .onChange(of: preferences.selectedRatio) { _, _ in updateOutputFraming() }
        .onChange(of: preferences.saveFramedOutput) { _, _ in updateOutputFraming() }
        .onChange(of: colorControls.recipe) { _, recipe in camera.setCameraColorRecipe(recipe) }
        .onChange(of: camera.logModeEnabled) { _, enabled in
            // Do not leave a hidden Saturation/Contrast dial active in Log.
            if enabled && ["Saturation", "Contrast"].contains(colorControls.selection) {
                colorControls.selection = "Clarity"
            }
            camera.setCameraColorRecipe(colorControls.recipe)
        }
        .onChange(of: camera.isRecording) { _, recording in
            orientation.setRecording(recording)
            if !recording { updateOutputFraming() }
        }
        .onChange(of: camera.exposureLocked) { _, locked in
            dismissAdjustment()
            if locked { colorDockExpanded = false }
            // Exposure compensation lives on the yellow target itself; no
            // separate AE dial or numerical readout is presented.
            exposureInspector = false
        }
        .onChange(of: photoEnabled) { _, enabled in
            if !enabled && camera.mode == .photo && !camera.isRecording { camera.toggleMode() }
        }
        .onChange(of: orientation.errorMessage) { _, message in
            if let message { camera.lastError = message; orientation.errorMessage = nil }
        }
        .onChange(of: expandedDock) { _, item in
            if item != nil {
                focusInspector = false
                exposureInspector = false
                colorDockExpanded = false
                openShortcutSide = nil
                shortcutAdjustment = nil
            }
        }
        .onChange(of: colorDockExpanded) { _, expanded in
            camera.setCameraColorsPreviewEnabled(expanded)
            if expanded {
                dismissAdjustment()
                openShortcutSide = nil
                shortcutAdjustment = nil
            }
        }
        .onChange(of: controlLayout) { _, _ in expandedDock = nil }
        .onChange(of: scenePhase) { _, _ in updateCameraActivity() }
        .onChange(of: showSettings) { _, _ in updateCameraActivity() }
        .onChange(of: showGallery) { _, _ in updateCameraActivity() }
        .onDisappear { camera.stop() }
        .fullScreenCover(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showGallery) { SavedMediaGallery() }
        .alert("Camera", isPresented: Binding(
            get: { camera.lastError != nil },
            set: { if !$0 { camera.lastError = nil } }
        )) { Button("OK", role: .cancel) { camera.lastError = nil } }
          message: { Text(camera.lastError ?? "") }
    }

    /// Keeps the portrait controls, left-side capture stack, and AF/readout
    /// rail out of the already large camera geometry view. Besides making the
    /// screen easier to review, this gives Swift a small unit to compile for
    /// physical devices rather than one monolithic inferred view type.
    private func mainCameraOverlay(previewFrame: CGRect, portrait: Bool, leftInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            if portrait { topBar(isPortrait: true) }
            if showRatioRuler && preferences.framingGuide && camera.mode == .photo {
                AspectRatioRuler(selection: $preferences.selectedRatio, isPortrait: portrait)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 20)
            if portrait { portraitCaptureCluster }
            bottomControls(isPortrait: portrait)
        }
        .padding(12)
        .frame(width: previewFrame.width, height: previewFrame.height)
        .overlay {
            if !portrait {
                leftCaptureToolStack
                    .position(x: leftInset + 34, y: previewFrame.minY + 68)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !portrait {
                VStack(alignment: .trailing, spacing: 8) {
                    previewFocusModes
                    cameraSwitchButton
                    statisticsRail
                }
                .frame(width: 64)
                .padding(.top, 9)
                .padding(.trailing, 12)
            }
        }
        .position(x: previewFrame.midX, y: previewFrame.midY)
        .zIndex(4)
    }

    /// Audio, Grid, and format share one compact vertical left-safe-area stack.
    private var leftCaptureToolStack: some View {
        VStack(spacing: 8) {
            Button(action: toggleAudioInspector) {
                AudioLevelMeters(levels: camera.audioLevels, height: 20, showsChannelLabels: true, orientation: .horizontal)
                    .frame(width: 46)
                    .frame(width: 64, height: 34)
                    .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Audio input and meters")
            .accessibilityHint("Tap to adjust audio input settings")
            .accessibilityIdentifier("camera.audio")
            gridPicker
            CaptureFormatToolStack(isExpanded: $showFormatChoices, onOpen: {
                showGridChoices = false
                showRatioChoices = false
                clearFocusTarget()
            })
        }
    }

    @ViewBuilder
    private var viewfinder: some View {
        if camera.authorization == .authorized {
            CameraPreview(camera: camera, onFocusHold: { devicePoint, displayPoint in
                camera.focus(at: devicePoint)
                showFocusTarget(at: displayPoint)
            }, onExposureTap: { openExposure(at: $0) }, onLensPinch: { towardTelephoto in
                // Pinch switches only between physical iPhone lenses. The
                // existing right-hand controls remain responsible for zoom.
                camera.cycleLens(towardTelephoto: towardTelephoto)
            })
                // Basic recipe controls use SwiftUI's compositor over the
                // native preview layer. The Metal Color Mix view already
                // includes these values through RecipeRenderer, so never
                // apply them a second time while it is active.
                .saturation(!camera.selectiveColorPreviewActive && !camera.logModeEnabled ? 1 + colorControls.recipe.saturation : 1)
                .contrast(!camera.selectiveColorPreviewActive && !camera.logModeEnabled ? 1 + colorControls.recipe.contrast + max(0, colorControls.recipe.clarity) * 0.20 : 1)
                .blur(radius: !camera.selectiveColorPreviewActive ? max(0, -colorControls.recipe.clarity) * 1.4 : 0)
                .accessibilityIdentifier("camera.preview")
                .accessibilityLabel("Camera preview")
                .accessibilityHint("Tap to lock exposure. Touch and hold a subject for one second to focus.")
                .accessibilityAction(named: Text("Focus at center")) {
                    camera.focus(at: CGPoint(x: 0.5, y: 0.5))
                    showFocusTarget(at: CGPoint(x: 0.5, y: 0.5))
                }
                .accessibilityAction(named: Text("Lock exposure at center")) { openExposure(at: CGPoint(x: 0.5, y: 0.5)) }
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    if let message = camera.health.message {
                        Text(message)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(InCamTheme.ivory)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(.top, 12)
                            .allowsHitTesting(false)
                            .accessibilityLabel(message)
                    }
                }
        } else {
            ZStack {
                LinearGradient(colors: [.black, Color(white: 0.16), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 10) {
                    Image(systemName: "camera.aperture").font(.system(size: 34, weight: .light))
                    Text(camera.authorization == .denied ? "Camera access is required" : "Preparing camera")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                }.foregroundStyle(InCamTheme.ivory.opacity(0.7))
            }
        }
    }

    private func topBar(isPortrait: Bool) -> some View {
        VStack(spacing: 4) {
            if isPortrait { Color.clear.frame(height: 36) }
            HStack(spacing: 8) {
                HStack {
                    exposureReadouts
                    Spacer()
                }
                if !isPortrait { ratioButtons(isPortrait: false) }
                if !isPortrait { modeAndSettings }
            }.frame(height: 44)
            if isPortrait {
                HStack {
                    modeAndSettings
                    Spacer(minLength: 6)
                    ratioButtons(isPortrait: true)
                }
            }
        }
        .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
    }

    private var elapsedReadout: some View {
        Text(camera.mode == .video ? format(camera.elapsed) : "PHOTO")
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(camera.isRecording ? InCamTheme.record : InCamTheme.ivory.opacity(0.76))
            .accessibilityIdentifier("status.elapsed")
    }

    private var exposureReadouts: some View {
        VStack(spacing: 8) {
            statusButton("WB", value: "\(Int(camera.temperature)) K", page: .whiteBalance)
            statusButton("TINT", value: String(format: "%+.0f", camera.tint / 12), page: .tint)
            statusButton("SHUTTER", value: shutterReadout, page: .shutter)
            statusButton("ISO", value: isoReadout, page: .iso)
        }
    }

    private var shutterReadout: String {
        // Speed mode reflects the live automatic exposure. Angle mode holds
        // its chosen value steady until the person changes shutter or FPS.
        let displaySeconds = camera.shutterAngleMode
            ? camera.lastManualExposureSeconds
            : camera.exposureSeconds
        let seconds = CameraExposureDefaults.displayDuration(
            for: displaySeconds,
            frameRate: camera.frameRate,
            angleMode: camera.shutterAngleMode,
            supportedRange: camera.capabilities.manualExposureRange
        )
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if camera.shutterAngleMode {
            return "\(Int(min(360, (seconds * Double(max(1, camera.frameRate)) * 360).rounded())))°"
        }
        return CameraExposureDefaults.speedLabel(seconds)
    }

    /// ISO preserves the selected discrete stop. The hardware may meter a
    /// value between stops while Auto is enabled.
    private var isoReadout: String {
        "\(Int(camera.iso.rounded()))"
    }

    private func statusButton(_ title: String, value: String, page: CameraControlPage) -> some View {
        Button {
            controlPage = page
            expandedDock = page.dockItem
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.system(size: 9, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                }
                HStack {
                    Text(value).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    Spacer(minLength: 2)
                    modePair(auto: autoState(for: page))
                }
            }
            .padding(.horizontal, 10).frame(width: 112, height: 44)
            .glass(in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(page.title(for: camera.mode))
        .accessibilityValue(value)
        .accessibilityHint("Open the shared adjustment box")
        .accessibilityIdentifier("status.\(title.lowercased())")
        // A simultaneous recognizer survives the Button's first tap, so a
        // second tap reliably performs the requested reset.
        .simultaneousGesture(TapGesture(count: 2).onEnded { resetControl(page) })
    }

    private func modePair(auto: Bool, focus: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(focus ? "AF" : "A").foregroundStyle(auto ? .yellow : InCamTheme.ivory.opacity(0.32))
            Text(focus ? "MF" : "M").foregroundStyle(auto ? InCamTheme.ivory.opacity(0.32) : .yellow)
        }.font(.system(size: 9, weight: .bold))
    }

    private func autoState(for page: CameraControlPage) -> Bool {
        switch page {
        case .whiteBalance: return camera.whiteBalanceAuto
        case .tint: return camera.tintAuto
        case .shutter: return camera.shutterAuto
        case .iso: return camera.isoAuto
        default: return false
        }
    }

    private var statisticsRail: some View {
        VStack(alignment: .trailing, spacing: 8) {
            statistic("WB", "\(Int(camera.temperature)) K", auto: camera.whiteBalanceAuto, page: .whiteBalance)
            statistic("TINT", String(format: "%+.0f", camera.tint / 12), auto: camera.tintAuto, page: .tint)
            statistic("SHUTTER", shutterReadout, auto: camera.shutterAuto, page: .shutter)
            statistic("ISO", isoReadout, auto: camera.isoAuto, page: .iso)
            if camera.aperture > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "ƒ%.1f", camera.aperture))
                        .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    Text("FIXED").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(InCamTheme.ivory.opacity(0.42))
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .trailing)
                .accessibilityLabel("Lens aperture")
                .accessibilityValue(String(format: "f %.1f, fixed by this lens", camera.aperture))
            }
        }.buttonStyle(PressScaleStyle())
            .shadow(color: .black, radius: 3, y: 1)
    }

    private func statistic(_ title: String, _ value: String, auto: Bool, page: CameraControlPage) -> some View {
        Button {
            let close = expandedDock != nil && controlPage == page
            controlPage = page
            expandedDock = close ? nil : page.dockItem
        } label: { VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.system(size: 10, weight: .medium)).monospacedDigit().lineLimit(1)
            modePair(auto: auto)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing).contentShape(Rectangle()) }
        .foregroundStyle(expandedDock != nil && controlPage == page ? .yellow : InCamTheme.ivory.opacity(0.8))
        .accessibilityLabel(page.title(for: camera.mode)).accessibilityValue(value)
        .accessibilityHint("Open adjustment at the Record button position")
        .accessibilityIdentifier("status.\(title.lowercased())")
        .simultaneousGesture(TapGesture(count: 2).onEnded { resetControl(page) })
    }

    /// Readout and dial double-taps share the same predictable baselines.
    /// The viewfinder itself keeps double-tap for AE Lock and target placement.
    private func resetControl(_ page: CameraControlPage) {
        switch page {
        case .whiteBalance:
            camera.setWhiteBalanceAuto(true)
        case .tint:
            camera.setTint(0)
        case .shutter:
            camera.toggleShutterAngleMode()
        case .iso:
            camera.setISO(100)
        default:
            break
        }
    }

    @ViewBuilder private func ratioButtons(isPortrait: Bool) -> some View {
        if preferences.framingGuide {
            Button {
                dismissAdjustment(); clearFocusTarget(); showGridChoices = false; showFormatChoices = false
                showRatioChoices.toggle()
            } label: {
                VStack(spacing: 1) {
                    Text(ratio.label(isPortrait: isPortrait)).font(.system(size: 11, weight: .semibold))
                    Text("RATIO").font(.system(size: 7, weight: .medium))
                }
                .foregroundStyle(.yellow)
                .frame(width: 64, height: 34)
                .glass(in: RoundedRectangle(cornerRadius: 10), emphasized: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Framing ratio")
            .accessibilityValue(ratio.rawValue)
            .accessibilityHint("Tap to show saved ratio choices")
            .accessibilityIdentifier("framing.choose")
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.48 : 1)
        }
    }

    private var gridPicker: some View {
        Button {
            // The grid icon is the composition entry point: it reveals one
            // cycling Ratio button and one cycling Grid button beside it.
            let opening = !showGridChoices
            showFormatChoices = false
            showGridChoices = opening
            showRatioChoices = false
            clearFocusTarget()
        } label: {
            GridChoiceIcon(mode: grid).frame(width: 16, height: 16)
            .foregroundStyle(grid == .off ? InCamTheme.ivory : .yellow)
            .frame(width: 64, height: 34)
            .glass(in: RoundedRectangle(cornerRadius: 10), emphasized: grid != .off)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Composition grid")
        .accessibilityValue(gridName(grid))
        .accessibilityHint("Tap to show framing ratio and grid choices")
        .accessibilityIdentifier("grid.choose")
    }

    private func cycleRatio() {
        guard !camera.isRecording else { return }
        let choices = preferences.ratioShortcuts
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex(of: preferences.selectedRatio) ?? -1
        preferences.selectedRatio = choices[(index + 1) % choices.count]
    }

    private func gridName(_ mode: GridMode) -> String {
        switch mode {
        case .off: return "Off"
        case .thirds: return "Thirds"
        case .golden: return "Golden Ratio"
        case .spiral: return "Fibonacci Spiral"
        case .diagonals: return "Diagonals"
        }
    }

    private func openZoom() {
        controlPage = .zoom
        expandedDock = .zoom
    }

    private func dismissAdjustment() {
        cancelFocusInspectorDismissal()
        focusInspector = false
        exposureInspector = false
        expandedDock = nil
    }

    /// Closes every temporary inspector after an outside double-tap. Keeping
    /// these assignments in a helper avoids an overly complex SwiftUI gesture
    /// closure, which otherwise fails to compile for a physical iPhone target.
    private func dismissTransientControls() {
        dismissAdjustment()
        clearFocusTarget()
        colorDockExpanded = false
        audioInspectorOpen = false
        showGridChoices = false
        showRatioChoices = false
        showFormatChoices = false
    }

    /// Audio opens as the only left-side tool inspector. This isolated action
    /// keeps the view-builder closure simple enough for device compilation.
    private func toggleAudioInspector() {
        dismissAdjustment()
        clearFocusTarget()
        colorDockExpanded = false
        showRatioChoices = false
        showGridChoices = false
        showFormatChoices = false
        audioInspectorOpen.toggle()
    }

    /// A focus target confirms the tap briefly, then fades away without
    /// changing the camera's actual focus mode or point. Any on-screen tool
    /// action also clears it immediately, keeping the composition UI clean.
    private func showFocusTarget(at point: CGPoint) {
        focusTargetDismissWorkItem?.cancel()
        focusTarget = point
        let work = DispatchWorkItem { focusTarget = nil }
        focusTargetDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }

    /// The ruler is a temporary second view over Record. Moving it locks the
    /// chosen focus position; releasing it for a moment restores Record while
    /// leaving that manual focus intact, including during a recording.
    private func scheduleFocusInspectorDismissal() {
        focusInspectorDismissWorkItem?.cancel()
        let work = DispatchWorkItem { focusInspector = false }
        focusInspectorDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func cancelFocusInspectorDismissal() {
        focusInspectorDismissWorkItem?.cancel()
        focusInspectorDismissWorkItem = nil
    }

    private func updateOutputFraming() {
        guard !camera.isRecording, preferences.saveFramedOutput, preferences.framingGuide else {
            if !camera.isRecording { camera.setOutputFraming(aspect: nil) }
            return
        }
        let aspect = orientation.interfaceOrientation.isPortrait ? 1 / ratio.value : ratio.value
        camera.setOutputFraming(aspect: aspect)
    }

    private func clearFocusTarget() {
        focusTargetDismissWorkItem?.cancel()
        focusTargetDismissWorkItem = nil
        focusTarget = nil
    }

    /// Separate view-builder boundary for the temporary inspector scrim. The
    /// main camera body is intentionally dense, so isolating this gesture
    /// avoids the physical-device compiler timing out while preserving its
    /// single-tap dismissal and double-tap exposure-lock behavior.
    private func transientControlsDismissalLayer(cameraRight: CGFloat, height: CGFloat) -> some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            // Keep this invisible tap catcher inside the live image. A
            // full-screen catcher can otherwise absorb dock/right-pad taps.
            .frame(width: cameraRight, height: height)
            .position(x: cameraRight / 2, y: height / 2)
            .gesture(SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture()).onEnded { value in
                switch value {
                case .first(let tap):
                    guard tap.location.x <= cameraRight else { return }
                    openExposure(at: CGPoint(x: tap.location.x / cameraRight, y: tap.location.y / height))
                case .second:
                    dismissTransientControls()
                }
            })
            .accessibilityLabel("Dismiss adjustment")
            .accessibilityIdentifier("controls.dismissOutside")
    }

    private var previewFocusModes: some View {
        Button {
            dismissAdjustment()
            colorDockExpanded = false
            showGridChoices = false
            showRatioChoices = false
            focusTarget = nil
            // Opening AF shows the current live lens position. It does not
            // lock focus until the person actually moves the ruler.
            focusInspector = true
        } label: {
            Text(camera.focusAuto ? "AF" : "MF")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: 64, height: 34)
                .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Focus mode")
        .accessibilityValue(camera.focusAuto ? "AF" : "MF")
        .accessibilityHint("Tap to show focus. Adjust to lock manual focus; double-tap to return to autofocus")
        .accessibilityIdentifier("focus.toggle")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            cancelFocusInspectorDismissal()
            camera.setFocus(auto: true)
            focusInspector = false
        })
    }

    /// Lives above WB in the same compact trailing rail as AF/MF and the
    /// camera readouts. It does not compete with the Record control column.
    private var cameraSwitchButton: some View {
        Button { camera.toggleCameraPosition() } label: {
            Image(systemName: "camera.rotate")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: 64, height: 30)
                .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.45 : 1)
        .accessibilityLabel("Switch camera")
        .accessibilityValue(camera.isFrontCamera ? "Front camera" : "Rear camera")
        .accessibilityHint("Switches between the front and rear cameras")
        .accessibilityIdentifier("camera.switch")
    }

    private func openExposure(at point: CGPoint) {
        exposureTarget = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        focusTarget = exposureTarget
        dismissAdjustment()
        colorDockExpanded = false
        showGridChoices = false
        showRatioChoices = false
        if !camera.exposureLocked { camera.toggleExposureLock() }
    }

    /// A completed target drag changes exposure one step, then settles its
    /// continuously-scaled 0.8×...1.5× feedback square back to neutral.
    private func adjustExposureTarget(increase: Bool) {
        camera.adjustExposureBias(by: increase ? 0.3 : -0.3)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
            exposureTargetPulse = 1
        }
    }

    private var modeToggle: some View {
        Group {
            if photoEnabled {
                Button { camera.toggleMode(); expandedDock = nil } label: {
                    Text(camera.mode == .video ? "V" : "P")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .frame(width: 52, height: 36)
                        .glass(in: Capsule(), emphasized: true)
                }
                .disabled(camera.isRecording)
                .opacity(camera.isRecording ? 0.45 : 1)
                .accessibilityLabel("Capture mode")
                .accessibilityValue(camera.mode == .video ? "Video" : "Photo")
                .accessibilityIdentifier("camera.mode")
            }
        }
        .buttonStyle(PressScaleStyle())
    }

    private var settingsButton: some View {
        Button { dismissAdjustment(); clearFocusTarget(); showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 52, height: 52)
                .glass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel("Settings")
        .accessibilityIdentifier("settings.open")
    }

    /// Gallery remains lower in the fixed right column with the same compact
    /// target and edge padding as Settings at the top-right of that surface.
    private var rightColumnUtilities: some View {
        Button { openGalleryOrStopRecording() } label: {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 52, height: 52)
                .glass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .accessibilityLabel("Saved photos and videos")
        .accessibilityIdentifier("gallery.open")
        .buttonStyle(PressScaleStyle())
    }

    private var modeAndSettings: some View {
        HStack(spacing: 8) {
            modeToggle

            Button { openGalleryOrStopRecording() } label: {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 14)).frame(width: 38, height: 36)
                    .glass(in: Capsule())
            }.accessibilityLabel("Saved photos and videos")

            Button { dismissAdjustment(); clearFocusTarget(); showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .frame(width: 38, height: 36)
                    .glass(in: Capsule())
            }
            .accessibilityLabel("Settings")
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Gallery is also a deliberate stop-recording target. This avoids opening
    /// an empty gallery while MovieFileOutput is still finalizing the clip.
    private func openGalleryOrStopRecording() {
        if camera.isRecording {
            camera.capture()
        } else {
            showGallery = true
        }
    }

    /// The camera is intentionally active only when its actual viewfinder is
    /// usable. Settings, Audio, Gallery, app switching, and backgrounding all
    /// release the camera, microphone meter, motion sensor, and zoom work.
    private func updateCameraActivity() {
        let cameraVisible = !showSettings && !showGallery
        if scenePhase == .active && cameraVisible {
            camera.start()
        } else {
            camera.stop()
        }
    }

    private var portraitCaptureCluster: some View {
        HStack {
            Spacer()
            HStack(spacing: 12) {
                CaptureButton()
                CaptureAccessory(onZoomBegin: { expandedDock = nil })
            }
        }
        .frame(height: 184)
    }

    private func bottomControls(isPortrait: Bool) -> some View {
        ZStack(alignment: .bottom) {
            if isPortrait && controlLayout == .dock && expandedDock != nil && expandedDock != .zoom {
                CameraDock(expanded: $expandedDock, page: $controlPage, showsPanel: controlLayout == .dock)
                    .frame(maxWidth: expandedDock == nil ? 110 : (isPortrait ? 356 : 420))
                    .frame(maxWidth: .infinity)
                    .zIndex(openShortcutSide == nil ? 1 : 0)
            }

            if !isPortrait {
            HStack {
                if preferences.showCustom1 && shortcuts.c1.contains(where: { $0 != .unassigned }) {
                ShortcutArc(side: .leading, name: shortcuts.c1Name, actions: shortcuts.c1, openSide: $openShortcutSide, onSelect: activateShortcut)
                    .offset(x: isPortrait ? -6 : -10, y: 12)
                }
                Spacer()
                if preferences.showCustom2 && shortcuts.c2.contains(where: { $0 != .unassigned }) {
                ShortcutArc(side: .trailing, name: shortcuts.c2Name, actions: shortcuts.c2, openSide: $openShortcutSide, onSelect: activateShortcut)
                    .offset(x: isPortrait ? 6 : 10, y: 12)
                }
            }
            .allowsHitTesting(expandedDock == nil)
            .onChange(of: openShortcutSide) { _, newSide in
                if let newSide, let current = shortcutAdjustment, current.side != newSide {
                    shortcutAdjustment = nil
                }
            }
            } else {
                HStack {
                    if preferences.showCustom1 && shortcuts.c1.contains(where: { $0 != .unassigned }) { portraitShortcut(.leading) }
                    Spacer()
                    if preferences.showCustom2 && shortcuts.c2.contains(where: { $0 != .unassigned }) { portraitShortcut(.trailing) }
                }
                .offset(y: -62)
                .allowsHitTesting(expandedDock == nil)
            }

            if !isPortrait, let shortcutAdjustment {
                ShortcutAdjustmentRail(
                    selection: shortcutAdjustment,
                    ratio: $preferences.selectedRatio,
                    grid: $grid,
                    gridDensity: $gridDensity,
                    onClose: { self.shortcutAdjustment = nil })
                    .frame(
                        maxWidth: .infinity,
                        alignment: shortcutAdjustment.side == .leading ? .leading : .trailing)
                    .padding(
                        shortcutAdjustment.side == .leading ? .leading : .trailing,
                        34 + CGFloat(shortcutAdjustment.index) * 24)
                    .offset(y: -88 - CGFloat(3 - shortcutAdjustment.index) * 23)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(height: isPortrait && controlLayout == .dock && expandedDock != nil && expandedDock != .zoom ? (preferences.showQuickRow ? 216 : 172) : 76, alignment: .bottom)
    }

    private func portraitShortcut(_ side: ShortcutSide) -> some View {
        let actions = (side == .leading ? shortcuts.c1 : shortcuts.c2).enumerated().filter { $0.element != .unassigned }
        let name = side == .leading ? shortcuts.c1Name : shortcuts.c2Name
        return Menu {
            ForEach(actions, id: \.offset) { entry in
                Button(entry.element.rawValue) { activateShortcut(entry.element, index: entry.offset, side: side) }
            }
            if actions.isEmpty { Button("Assign in Settings") { showSettings = true } }
        } label: {
            Text(actions.count == 1 ? actions[0].element.rawValue : name)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 44)
                .glass(in: Capsule())
        }
    }

    private func cycleGrid() {
        let active = GridMode.choices
        let index = active.firstIndex(of: grid) ?? -1
        let next = active[(index + 1) % active.count]
        if next != .off { lastGrid = next }
        grid = next
    }

    private func activateShortcut(_ action: ShortcutAction, index: Int, side: ShortcutSide) {
        let supportsRail: Bool
        switch action {
        case .unassigned: supportsRail = false
        case .aspectRatio:
            showRatioRuler = false
            supportsRail = true
        case .whiteBalance, .shutter, .iso:
            let item: DockItem = action == .whiteBalance ? .whiteBalance : (action == .iso ? .iso : .shutter)
            controlPage = CameraControlPage(item)
            expandedDock = item
            supportsRail = false
        case .cameraColor:
            controlPage = .cameraColor
            expandedDock = .cameraColor
            supportsRail = false
        case .grid:
            if orientation.interfaceOrientation.isPortrait { cycleGrid() }
            else if grid == .off { grid = lastGrid }
            supportsRail = true
        case .level:
            levelEnabled.toggle()
            supportsRail = false
        case .focus, .exposureCompensation:
            supportsRail = false
        }
        if orientation.interfaceOrientation.isPortrait {
            if action == .aspectRatio { showRatioRuler = true }
            shortcutAdjustment = nil
            return
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
            shortcutAdjustment = supportsRail
                ? ShortcutAdjustment(action: action, index: index, side: side)
                : nil
        }
    }

    private func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// Camera Control / supported hardware capture events are routed through the
/// same capture path as the red button. Unsupported iPhones keep the regular
/// on-screen controls without a fallback gesture that could steal volume keys.
private struct PhysicalCaptureEventModifier: ViewModifier {
    let enabled: Bool
    let capture: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onCameraCaptureEvent(isEnabled: enabled) { event in
                if event.phase == .ended { capture() }
            }
        } else {
            content
        }
    }
}

/// Keeps the floating inspector clear of the capture/zoom cluster and top bar.
/// Relative placement survives rotation; the handle alone owns the move gesture.
private struct FloatingCameraControls: View {
    @EnvironmentObject private var preferences: CameraScreenPreferences
    @Binding var expanded: DockItem?
    @Binding var page: CameraControlPage
    let viewport: CGSize
    let safeArea: EdgeInsets
    @State private var placement = CGPoint(x: 0.88, y: 1)
    @State private var dragOrigin: CGPoint?

    var body: some View {
        let portrait = viewport.height > viewport.width
        let left = max(12, safeArea.leading + 8)
        let right = max(12, safeArea.trailing + 8) + (portrait ? 0 : 94)
        let width = min(356, max(260, viewport.width - left - right))
        let height: CGFloat = preferences.showQuickRow ? 228 : 184
        let top = max(12, safeArea.top) + (portrait ? 96 : 48)
        let bottom = viewport.height - max(12, safeArea.bottom) - (portrait ? 220 : 24)
        let travelX = max(0, viewport.width - left - right - width)
        let travelY = max(0, bottom - top - height)
        let x = left + travelX * placement.x
        let y = top + travelY * placement.y

        VStack(spacing: 0) {
            Capsule().fill(.white.opacity(0.38)).frame(width: 32, height: 3)
                .frame(maxWidth: .infinity).frame(height: 24)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        if dragOrigin == nil { dragOrigin = placement }
                        guard let origin = dragOrigin else { return }
                        placement = CGPoint(
                            x: min(1, max(0, origin.x + value.translation.width / max(1, travelX))),
                            y: min(1, max(0, origin.y + value.translation.height / max(1, travelY))))
                    }
                    .onEnded { _ in dragOrigin = nil })
                .onTapGesture(count: 2) { placement = CGPoint(x: 0.88, y: 1) }
                .accessibilityLabel("Move control box")
                .accessibilityIdentifier("controls.dragHandle")
                .accessibilityHint("Drag to move; double tap to reset position")
            CameraDock(expanded: $expanded, page: $page, floating: true)
        }
        .frame(width: width, height: height)
        .background(.ultraThinMaterial)
        .background(InCamTheme.graphite.opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.16), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .position(x: x + width / 2, y: y + height / 2)
    }
}

private struct ShortcutAdjustment: Equatable {
    let action: ShortcutAction
    let index: Int
    let side: ShortcutSide
}

/// A compact ruler that follows the selected C1/C2 sector instead of opening
/// at a fixed screen location.
private struct ShortcutAdjustmentRail: View {
    @EnvironmentObject private var camera: CameraController
    let selection: ShortcutAdjustment
    @Binding var ratio: CompositionRatio
    @Binding var grid: GridMode
    @Binding var gridDensity: Int
    let onClose: () -> Void
    @State private var whiteBalanceAxis: WhiteBalanceAxis? = .temperature

    @ViewBuilder
    var body: some View {
        if selection.action == .whiteBalance {
            whiteBalanceControl
        } else if selection.action == .grid {
            gridControl
        } else {
            standardControl
        }
    }

    private var gridControl: some View {
        VStack(spacing: 6) {
            HStack {
                Text("GRID DESIGN")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 24, height: 24)
                        .glass(in: Circle())
                }
                .buttonStyle(PressScaleStyle())
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                ForEach([GridMode.thirds, .golden, .diagonals], id: \.self) { option in
                    Button { grid = option } label: {
                        Text(gridTitle(option))
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(InCamTheme.ivory)
                            .frame(maxWidth: .infinity, minHeight: 27)
                            .glass(in: RoundedRectangle(cornerRadius: 7), emphasized: grid == option)
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 218, height: 105)
        .glass(in: RoundedRectangle(cornerRadius: 20), emphasized: true)
        .modifier(ShortcutLeader(side: selection.side))
    }

    private func gridTitle(_ mode: GridMode) -> String {
        switch mode {
        case .off: return "OFF"
        case .thirds: return "RULE OF THIRDS"
        case .golden: return "GOLDEN RATIO"
        case .spiral: return "GOLDEN SPIRAL"
        case .diagonals: return "DIAGONAL"
        }
    }

    private var standardControl: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                    Text(valueLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(InCamTheme.ivory.opacity(0.65))
                }
                AdjustmentLine(value: valueBinding, range: valueRange, steps: steps, width: 136)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 28, height: 28)
                    .glass(in: Circle())
            }
            .buttonStyle(PressScaleStyle())
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .frame(width: 198, height: 60)
        .glass(in: Capsule(), emphasized: true)
        .modifier(ShortcutLeader(side: selection.side))
    }

    private var whiteBalanceControl: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text("WHITE BALANCE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                Spacer(minLength: 2)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 24, height: 24)
                        .glass(in: Circle())
                }
                .buttonStyle(PressScaleStyle())
            }

            HStack(spacing: 6) {
                axisButton(.temperature, title: "WHITE BALANCE")
                axisButton(.tint, title: "TINT")
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onEnded { gesture in
                        whiteBalanceAxis = gesture.translation.width < 0 ? .tint : .temperature
                    }
            )

            if let whiteBalanceAxis {
                HStack(spacing: 6) {
                    Text(whiteBalanceAxis == .temperature
                         ? "\(Int(camera.temperature)) K"
                         : "TINT \(Int(camera.tint))")
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .frame(width: 52, alignment: .leading)
                    AdjustmentLine(
                        value: whiteBalanceAxis == .temperature ? temperatureBinding : tintBinding,
                        range: whiteBalanceAxis == .temperature ? 2_000...10_000 : -100...100,
                        steps: 11,
                        width: 126)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(width: 218, height: whiteBalanceAxis == nil ? 70 : 96)
        .glass(in: RoundedRectangle(cornerRadius: 22), emphasized: true)
        .modifier(ShortcutLeader(side: selection.side))
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: whiteBalanceAxis)
    }

    private func axisButton(_ axis: WhiteBalanceAxis, title: String) -> some View {
        Button {
            whiteBalanceAxis = axis
        } label: {
            Text(title)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(InCamTheme.ivory)
                .frame(maxWidth: .infinity, minHeight: 27)
                .glass(in: RoundedRectangle(cornerRadius: 7), emphasized: whiteBalanceAxis == axis)
        }
        .buttonStyle(PressScaleStyle())
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: { Double(camera.temperature) },
            set: { camera.setTemperature(Float($0)) })
    }

    private var tintBinding: Binding<Double> {
        Binding(
            get: { Double(camera.tint) },
            set: { camera.setTint(Float($0)) })
    }

    private enum WhiteBalanceAxis {
        case temperature
        case tint
    }
}

private struct ShortcutLeader: ViewModifier {
    let side: ShortcutSide

    func body(content: Content) -> some View {
        content
        .overlay(alignment: side == .leading ? .bottomLeading : .bottomTrailing) {
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: side == .leading ? 18 : -18, y: 22))
            }
            .stroke(InCamTheme.ivory.opacity(0.62), lineWidth: 1)
            .frame(width: 18, height: 22)
            .offset(x: side == .leading ? 18 : -18, y: 18)
            .allowsHitTesting(false)
        }
    }
}

private extension ShortcutAdjustmentRail {
    var title: String {
        switch selection.action {
        case .aspectRatio: return "ASPECT"
        case .whiteBalance: return "WHITE BALANCE"
        case .shutter: return "SHUTTER"
        case .iso: return "ISO"
        case .grid: return "GRID SIZE"
        default: return selection.action.rawValue.uppercased()
        }
    }

    var valueLabel: String {
        switch selection.action {
        case .aspectRatio: return ratio.rawValue
        case .whiteBalance: return "\(Int(camera.temperature)) K"
        case .shutter: return "1/\(max(1, Int(pow(2, shutterStops).rounded())))"
        case .iso: return "\(Int(camera.iso))"
        case .grid: return "\(gridDensity) × \(gridDensity)"
        default: return ""
        }
    }

    var valueRange: ClosedRange<Double> {
        switch selection.action {
        case .aspectRatio: return 0...Double(CompositionRatio.allCases.count - 1)
        case .whiteBalance: return 2_000...10_000
        case .shutter:
            let range = camera.capabilities.manualExposureRange
            return -log2(range.upperBound)...(-log2(range.lowerBound))
        case .iso: return Double(camera.capabilities.minISO)...Double(camera.capabilities.maxISO)
        case .grid: return 2...6
        default: return 0...1
        }
    }

    var steps: Int {
        switch selection.action {
        case .aspectRatio: return CompositionRatio.allCases.count
        case .grid: return 5
        default: return 11
        }
    }

    var shutterStops: Double {
        -log2(max(0.00001, camera.exposureSeconds))
    }

    var valueBinding: Binding<Double> {
        switch selection.action {
        case .aspectRatio:
            return Binding(
                get: { Double(CompositionRatio.allCases.firstIndex(of: ratio) ?? 0) },
                set: { ratio = CompositionRatio.allCases[min(CompositionRatio.allCases.count - 1, max(0, Int($0.rounded())))] })
        case .whiteBalance:
            return Binding(
                get: { Double(camera.temperature) },
                set: { camera.setTemperature(Float($0)) })
        case .shutter:
            return Binding(
                get: { shutterStops },
                set: { camera.setExposure(pow(2, -$0)) })
        case .iso:
            return Binding(
                get: { Double(camera.iso) },
                set: { camera.setISO(Float($0)) })
        case .grid:
            return Binding(
                get: { Double(gridDensity) },
                set: {
                    gridDensity = min(6, max(2, Int($0.rounded())))
                    if grid == .off { grid = .thirds }
                })
        default:
            return .constant(0)
        }
    }
}

private struct AdjustmentLine: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let steps: Int
    var width: CGFloat = 136

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 1)
                HStack(spacing: 0) {
                    ForEach(0..<max(2, steps), id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.42))
                            .frame(width: 1, height: index.isMultiple(of: 2) ? 11 : 7)
                        if index < max(2, steps) - 1 { Spacer(minLength: 0) }
                    }
                }
                Capsule()
                    .fill(InCamTheme.ivory)
                    .frame(width: 3, height: 22)
                    .offset(x: thumbOffset(width: proxy.size.width) - 1.5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let fraction = min(1, max(0, gesture.location.x / max(1, proxy.size.width)))
                        let raw = range.lowerBound + Double(fraction) * (range.upperBound - range.lowerBound)
                        let interval = (range.upperBound - range.lowerBound) / Double(max(1, steps - 1))
                        value = (raw / interval).rounded() * interval
                    }
            )
        }
        .frame(width: width, height: 24)
    }

    private func thumbOffset(width: CGFloat) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return width * CGFloat(min(1, max(0, fraction)))
    }
}

private struct LandscapeCaptureCluster: View {
    @EnvironmentObject private var camera: CameraController
    let onZoomBegin: () -> Void
    var body: some View {
        Group {
            if camera.mode == .video {
                CamcorderCaptureRocker(onZoomBegin: onZoomBegin)
            } else {
                VStack(spacing: 12) {
                    CaptureButton(size: 70)
                    CaptureAccessory(compact: true, onZoomBegin: onZoomBegin)
                }
            }
        }
        .frame(width: 88, height: 190)
    }
}

/// A drag takes ownership from the record tap until release. The target never moves.
private struct CamcorderCaptureRocker: View {
    @EnvironmentObject private var camera: CameraController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var zooming = false
    @State private var startZoom: CGFloat?
    @GestureState private var slowPressActive = false
    @State private var slowZoomTask: Task<Void, Never>?
    var showsCapture = true
    let onZoomBegin: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            zoomStep("plus", amount: 0.1)
            if showsCapture {
                CaptureButton(size: 70)
                    .disabled(zooming)
                    .opacity(zooming ? 0.28 : 1)
                    .overlay {
                        if zooming {
                            Text(String(format: "%.1f×", camera.zoom))
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .monospacedDigit().foregroundStyle(.yellow)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                Text(String(format: "%.1f×", camera.zoom))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(InCamTheme.ivory.opacity(0.8))
                    .frame(width: 48, height: 20)
            }
            zoomStep("minus", amount: -0.1)
        }
        .frame(width: 76)
        .contentShape(Capsule())
        .highPriorityGesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($zooming) { _, active, _ in active = true }
            .onChanged { gesture in
                if startZoom == nil { stopSlowZoom(); startZoom = camera.zoom; onZoomBegin() }
                camera.setZoomVelocity(Double(min(1, max(-1, -gesture.translation.height / 70))))
            }
            .onEnded { _ in stopZoom() })
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: zooming)
        .onChange(of: zooming) { _, active in if !active { stopZoom() } }
        .onChange(of: slowPressActive) { _, active in if !active { stopSlowZoom() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stopZoom() } }
        .onDisappear { stopZoom() }
        .accessibilityIdentifier("zoom.recordRocker")
    }

    private func zoomStep(_ symbol: String, amount: CGFloat) -> some View {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .glass(in: Circle())
                .frame(width: 64, height: 44)
                .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .updating($slowPressActive) { _, active, _ in active = true }
            .onChanged { _ in
                guard slowZoomTask == nil else { return }
                onZoomBegin()
                camera.stopZoomRamp()
                camera.setZoom(camera.zoom + amount)
                slowZoomTask = Task { @MainActor in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        camera.setZoom(camera.zoom + amount)
                    }
                }
            }
            .onEnded { _ in stopSlowZoom() })
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onZoomBegin(); camera.setZoom(camera.zoom + amount) }
        .accessibilityLabel(amount > 0 ? "Zoom in" : "Zoom out")
        .accessibilityValue(String(format: "%.1f×", camera.zoom))
        .accessibilityHint("Tap for 0.1 times zoom. Hold to repeat once per second; release to stop.")
        .accessibilityIdentifier("zoom.\(symbol)")
    }

    private func stopZoom() {
        stopSlowZoom()
        camera.stopZoomRamp()
        startZoom = nil
    }

    private func stopSlowZoom() {
        slowZoomTask?.cancel()
        slowZoomTask = nil
    }
}

/// Video zoom and photo lens selection occupy the same fixed accessory slot.
private struct CaptureAccessory: View {
    @EnvironmentObject private var camera: CameraController
    var compact = false
    let onZoomBegin: () -> Void

    var body: some View {
        Group {
            if camera.mode == .video {
                TouchZoomControl(compact: compact, onBegin: onZoomBegin)
            } else {
                LensSwitcher()
            }
        }
        .frame(width: compact ? 44 : 60, height: compact ? 44 : 164)
    }
}

private struct LensSwitcher: View {
    @EnvironmentObject private var camera: CameraController

    private var selectedLens: CameraLensOption? {
        camera.lenses.first { $0.id == camera.selectedLensID }
    }

    var body: some View {
        Button { cycleLens() } label: {
                VStack(spacing: 1) {
                    Text(selectedLens?.equivalentMillimeters.map { "\(selectedLens?.isPreview == true ? "" : "≈")\($0)" } ?? "Lens")
                        .font(.system(size: 11, weight: .semibold))
                    if selectedLens?.equivalentMillimeters != nil { Text("mm").font(.system(size: 8)) }
                }
                .foregroundStyle(.yellow)
                .frame(width: 44, height: 44)
                .background(.yellow.opacity(0.12), in: Circle())
                .glass(in: Circle(), emphasized: true)
            }
            .accessibilityLabel("Camera lens")
            .accessibilityValue(selectedLens?.millimeterLabel ?? "Unavailable")
            .accessibilityHint("Tap to cycle to the next available lens")
            .accessibilityIdentifier("lens.choose")
        .buttonStyle(.plain)
        .disabled(camera.isRecording || camera.lenses.isEmpty)
        .opacity(camera.isRecording ? 0.5 : 1)
    }

    /// Photo mode uses one stable circular lens control; each tap advances the
    /// mm label and switches the physical lens instead of opening a chooser.
    private func cycleLens() {
        guard !camera.lenses.isEmpty else { return }
        let index = camera.lenses.firstIndex { $0.id == camera.selectedLensID } ?? -1
        let next = camera.lenses[(index + 1) % camera.lenses.count]
        camera.selectLens(next.id)
    }
}

private struct ZoomLauncher: View {
    @EnvironmentObject private var camera: CameraController
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(String(format: "%.1f×", camera.zoom))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(width: 64, height: 36)
                .glass(in: Capsule())
        }
        .accessibilityLabel("Zoom controls")
        .accessibilityIdentifier("zoom.open")
    }
}

/// Small rectangular output controls that live directly below the Audio
/// meters, matching Ratio and Grid rather than introducing a second shape.
/// Each control cycles only through values reported by the current camera; an
/// unavailable hardware feature stays visibly unavailable instead of acting
/// like a setting that cannot actually be captured.
private struct CaptureFormatToolStack: View {
    @EnvironmentObject private var camera: CameraController
    @Binding var isExpanded: Bool
    let onOpen: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            Button {
                let opening = !isExpanded
                isExpanded.toggle()
                if opening { onOpen() }
            } label: {
                Text("\(camera.videoResolution.compactLabel) \(camera.frameRate) FPS")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .foregroundStyle(InCamTheme.ivory)
                    .frame(width: 64, height: 34)
                    .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), emphasized: isExpanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Video format")
            .accessibilityValue("\(camera.videoResolution.compactLabel), \(camera.frameRate) frames per second")
            .accessibilityHint("Tap to show resolution, frame rate, codec, RAW, and Log choices")

            if isExpanded {
                HStack(spacing: 8) {
                    formatButton(title: "RES", value: camera.videoResolution.compactLabel, action: cycleResolution)
                    formatButton(title: "FPS", value: "\(camera.frameRate)", action: cycleFrameRate)
                    formatButton(title: "CODEC", value: camera.videoCodec.compactLabel, action: cycleCodec)
                    formatButton(title: "RAW", value: camera.rawPhotoSupported ? "PHOTO" : "N/A", action: rawStatus)
                        .opacity(camera.rawPhotoSupported ? 1 : 0.45)
                    formatButton(title: "LOG", value: camera.logModeEnabled ? "ON" : "OFF", action: toggleLog)
                }
                .offset(x: 72)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        // The option buttons are siblings of the main button, never nested
        // inside it. A tap on 4K, 30 FPS, or a codec therefore changes only
        // that value and cannot re-trigger the main panel button.
        .frame(width: 64, height: 34, alignment: .leading)
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.48 : 1)
    }

    private func formatButton(title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(value).font(.system(size: 9, weight: .bold, design: .rounded)).lineLimit(1)
                Text(title).font(.system(size: 6, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(InCamTheme.ivory)
            .frame(width: 64, height: 34)
            // The adjacent choices are deliberately quieter than the fixed
            // format button. Log alone carries a selected-state emphasis.
            .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), emphasized: title == "LOG" && camera.logModeEnabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func cycleResolution() {
        let choices = camera.availableVideoResolutions
        guard let index = choices.firstIndex(of: camera.videoResolution), !choices.isEmpty else { return }
        camera.setVideoResolution(choices[(index + 1) % choices.count])
    }

    private func cycleFrameRate() {
        let choices = camera.capabilities.frameRates.filter { [24, 25, 30, 60].contains($0) }
        guard let index = choices.firstIndex(of: camera.frameRate), !choices.isEmpty else { return }
        camera.setFrameRate(choices[(index + 1) % choices.count])
    }

    private func cycleCodec() {
        let choices = camera.availableVideoCodecs
        guard let index = choices.firstIndex(of: camera.videoCodec), !choices.isEmpty else { return }
        camera.setVideoCodec(choices[(index + 1) % choices.count])
    }

    private func rawStatus() {
        camera.lastError = camera.rawPhotoSupported
            ? "RAW is supported by this camera. RAW saving will be enabled with the dedicated photo pipeline."
            : "RAW is unavailable on this camera's current format."
    }

    private func toggleLog() {
        camera.setLogModeEnabled(!camera.logModeEnabled)
    }
}

/// A small in-camera audio card. The complete audio page still exists in
/// Settings; this surface is intentionally limited to the controls that can
/// be changed quickly while framing a shot.
private struct CompactAudioInspector: View {
    @EnvironmentObject private var camera: CameraController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            channelModeSelector
            routeMenu(title: "INPUT", value: selectedInputName, isMuted: false) {
                if !camera.isRecording, !camera.audioInputs.isEmpty {
                    ForEach(camera.audioInputs) { input in
                        Button(input.name) { camera.selectAudioInput(input.id) }
                    }
                } else {
                    Text("Unavailable")
                }
            }
            routeMenu(title: "OUTPUT", value: outputName, isMuted: camera.audioOutputMode == .system) {
                ForEach(AudioOutputMode.allCases) { mode in
                    Button(mode == .system ? "None" : "Speaker") {
                        camera.setAudioOutputMode(mode)
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 132, alignment: .leading)
        .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), emphasized: true)
        .foregroundStyle(InCamTheme.ivory)
        .accessibilityIdentifier("audio.compactInspector")
    }

    private var selectedInputName: String {
        camera.audioInputs.first(where: { $0.id == camera.audioInputID })?.name ?? "None"
    }

    private var outputName: String {
        camera.audioOutputMode == .system ? "None" : "Speaker"
    }

    private var channelModeSelector: some View {
        HStack(spacing: 4) {
            ForEach(AudioChannelMode.allCases) { mode in
                Button(mode == .mono ? "MONO" : "STEREO") { camera.setAudioChannelMode(mode) }
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(camera.audioChannelMode == mode ? .yellow : InCamTheme.ivory.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 24)
                    .glass(in: RoundedRectangle(cornerRadius: 7, style: .continuous), emphasized: camera.audioChannelMode == mode)
                    .accessibilityLabel(mode.rawValue)
            }
        }
        .disabled(camera.isRecording)
    }

    private func routeMenu<MenuItems: View>(title: String, value: String, isMuted: Bool,
                                             @ViewBuilder items: () -> MenuItems) -> some View {
        Menu(content: items) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 7, weight: .bold))
                Spacer(minLength: 3)
                Text(value).lineLimit(1)
                    .foregroundStyle(isMuted ? InCamTheme.ivory.opacity(0.42) : InCamTheme.ivory)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 8, weight: .medium))
            .frame(height: 24)
            .padding(.horizontal, 7)
            .glass(in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

/// A compact alternate-value column placed immediately to the right of the
/// fixed Ratio or Grid button. It never uses a second selected style: exactly
/// one current value is yellow and the remaining choices stay charcoal.
private struct CompositionCyclingRow: View {
    let ratio: CompositionRatio
    let grid: GridMode
    let levelEnabled: Bool
    let cycleRatio: () -> Void
    let cycleGrid: () -> Void
    let toggleLevel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            choiceButton(label: ratio.rawValue, title: "RATIO", action: cycleRatio)
            choiceButton(label: grid.shortLabel, title: "GRID", action: cycleGrid)
            choiceButton(label: levelEnabled ? "ON" : "OFF", title: "LEVEL", action: toggleLevel)
        }
    }

    private func choiceButton(label: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(label).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 6, weight: .medium))
            }
            .foregroundStyle(InCamTheme.ivory.opacity(0.72))
            .frame(width: 64, height: 34)
            .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cycle \(title.lowercased())")
        .accessibilityValue(label)
    }
}

/// Ratio and Grid deliberately open together: they are composition choices,
/// and never imply that InCam crops or changes the recording file.
private struct CompositionChoicesPanel: View {
    let ratio: CompositionRatio
    let grid: GridMode
    let ratios: [CompositionRatio]
    let ratioEnabled: Bool
    let onRatio: (CompositionRatio) -> Void
    let onGrid: (GridMode) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                Text("RATIO").font(.system(size: 7, weight: .bold)).foregroundStyle(InCamTheme.ivory.opacity(0.55))
                ForEach(ratios) { choice in
                    Button { onRatio(choice) } label: {
                        Text(choice.rawValue).font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(choice == ratio ? .yellow : InCamTheme.ivory)
                            .frame(width: 42, height: 22)
                            .glass(in: RoundedRectangle(cornerRadius: 7), emphasized: choice == ratio)
                    }.buttonStyle(.plain)
                }
            }
            .opacity(ratioEnabled ? 1 : 0.45)
            .disabled(!ratioEnabled)

            VStack(alignment: .leading, spacing: 4) {
                Text("GRID").font(.system(size: 7, weight: .bold)).foregroundStyle(InCamTheme.ivory.opacity(0.55))
                ForEach(GridMode.choices, id: \.rawValue) { choice in
                    Button { onGrid(choice) } label: {
                        HStack(spacing: 4) {
                            GridChoiceIcon(mode: choice).frame(width: 10, height: 10)
                            Text(choice.shortLabel).font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(choice == grid ? .yellow : InCamTheme.ivory)
                        .frame(width: 48, height: 22)
                        .glass(in: RoundedRectangle(cornerRadius: 7), emphasized: choice == grid)
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(7)
        .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ratio and grid choices")
    }
}

private struct CaptureButton: View {
    @EnvironmentObject private var camera: CameraController
    var size: CGFloat = 70

    var body: some View {
        Button { camera.capture() } label: {
            ZStack {
                if camera.mode == .photo && camera.isCapturingPhoto {
                    // A square is an immediate, camera-style acknowledgement
                    // that a still image is currently being captured.
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white)
                        .frame(width: size * 0.48, height: size * 0.48)
                } else {
                    Circle()
                        .fill(camera.mode == .video ? InCamTheme.record : .white)
                        .frame(width: size, height: size)
                }
                if camera.isRecording {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white)
                        .frame(width: 25, height: 25)
                }
            }
            .frame(width: size + 12, height: size + 12)
            .glass(in: Circle(), emphasized: camera.isRecording)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(camera.mode == .photo ? "Take photo" : (camera.isRecording ? "Stop recording" : "Record"))
        .accessibilityIdentifier("camera.capture")
    }
}

private struct AspectRatioRuler: View {
    @Binding var selection: CompositionRatio
    let isPortrait: Bool
    @State private var startIndex: Int?

    var body: some View {
        VStack(spacing: 5) {
            Text("FRAMING GUIDE")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(InCamTheme.ivory.opacity(0.5))
            HStack(spacing: 0) {
                ForEach(CompositionRatio.allCases) { ratio in
                    Button { choose(ratio) } label: {
                        VStack(spacing: 4) {
                            Text(ratio.label(isPortrait: isPortrait))
                                .font(.system(size: 11, weight: ratio == selection ? .bold : .medium,
                                              design: .rounded))
                            Capsule()
                                .fill(ratio == selection ? InCamTheme.ivory : .white.opacity(0.25))
                                .frame(width: ratio == selection ? 3 : 1,
                                       height: ratio == selection ? 18 : 10)
                        }
                        .foregroundStyle(ratio == selection ? InCamTheme.ivory : InCamTheme.ivory.opacity(0.5))
                        .frame(width: 54, height: 38)
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { gesture in
                        if startIndex == nil {
                            startIndex = CompositionRatio.allCases.firstIndex(of: selection) ?? 0
                        }
                        let delta = Int((-gesture.translation.width / 38).rounded())
                        let index = min(CompositionRatio.allCases.count - 1,
                                        max(0, (startIndex ?? 0) + delta))
                        choose(CompositionRatio.allCases[index])
                    }
                    .onEnded { _ in startIndex = nil }
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(width: 348)
        .glass(in: RoundedRectangle(cornerRadius: 16), emphasized: true)
    }

    private func choose(_ ratio: CompositionRatio) {
        withAnimation(.easeInOut(duration: 0.18)) { selection = ratio }
    }
}
