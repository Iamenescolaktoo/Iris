import AVFoundation
import AVKit
import SwiftUI
import UIKit

// FILE GUIDE: The main camera composition. It positions preview, overlays,
// thumb controls, dock, Settings and Gallery, then translates gestures into
// CameraController commands. It owns presentation state, not AVFoundation.

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
    @AppStorage("incam.monitor.scope.mode") private var savedSceneScopeMode = SceneScopeMode.off.rawValue

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
    @State private var showScopeChoices = false
    /// The monitor may momentarily grow, without changing its analyser mode.
    @State private var sceneScopeExpanded = false
    /// A left swipe from the monitor folds it into a small circular launcher;
    /// it does not turn the analyser off or discard the selected scope mode.
    @State private var sceneScopeCollapsed = false
    @State private var previewZoomOrigin: CGFloat?
    @State private var previewZoomRulerVisible = false
    @State private var previewZoomDismissWorkItem: DispatchWorkItem?
    @State private var focusTarget: CGPoint?
    @State private var focusTargetDismissWorkItem: DispatchWorkItem?
    @State private var focusInspector = false
    @State private var focusInspectorDismissWorkItem: DispatchWorkItem?
    @State private var exposureInspector = false
    @State private var exposureTarget = CGPoint(x: 0.5, y: 0.5)
    @State private var exposureTargetPulse: CGFloat = 1
    @State private var exposureTargetDragStartBias: Float?
    @State private var exposureTargetLastStep = 0
    @State private var colorDockExpanded = false
    @State private var cameraColorProfilesOpen = false
    @State private var cameraColorEditorOpen = false
    @State private var cameraColorEditorSlot: Int?
    @State private var colorWheelExpanded = false
    /// The image-based Color workspace is a separate full-screen task. It
    /// never attaches the optional live camera color renderer while open.
    @State private var colorWorkspaceOpen = false
    @StateObject private var colorControls = ColorDockControls()
    @State private var showGallery = false
    @State private var openShortcutSide: ShortcutSide?
    @State private var shortcutAdjustment: ShortcutAdjustment?

    private var adjustmentExpanded: Bool { expandedDock != nil }
    /// A scope is bright while active and fades back after an outside tap.
    @State private var sceneScopeFocused = false
    /// The scope picker appears at the last held point, so its selected middle
    /// row is exactly under the user's thumb instead of at a fixed corner.
    @State private var sceneScopeMenuLocation: CGPoint?

    /// The scope choice is persisted as a small preference, while the costly
    /// frame analyser is controlled separately by CameraController.
    private var sceneScopeMode: SceneScopeMode {
        SceneScopeMode(rawValue: savedSceneScopeMode) ?? .off
    }

    /// New profiles always target the first empty visible CC slot. The saved
    /// recipe itself is written only by the editor's explicit Save action.
    private var nextCustomColorSlot: Int? {
        Array(colors.quickSlots.indices.prefix(5)).first(where: { colors.quickSlots[$0] == nil })
    }

    var body: some View {
        GeometryReader { proxy in
            let portrait = proxy.size.height > proxy.size.width
            // Fixed width: an open tool must never push the live camera into
            // the charcoal control rectangle or move that rectangle itself.
            // This width is deliberately constant. Gallery, Record, and
            // Settings share its one vertical control column; the live camera
            // image must never move into this charcoal surface.
            /// The visible right-hand mousepad is exactly 160 points wide.
            let rightControls: CGFloat = 160
            let leadingNotch: CGFloat = portrait ? 0 : 39
            let previewFrame = PreviewLayout.frame(in: proxy.size, ratio: ratio, portrait: portrait,
                                                  safeLeft: orientation.windowSafeAreaInsets.left,
                                                  safeRight: orientation.windowSafeAreaInsets.right,
                                                  adjustmentExpanded: adjustmentExpanded, rightControls: rightControls,
                                                  leadingNotch: leadingNotch)
            // Reserve outside margins for the statistics/dial and capture controls.
            let leftInset = max(12, orientation.windowSafeAreaInsets.left)
            // The color dock belongs to the live camera rectangle, not to the
            // full phone. The remaining trailing width is for thumb controls.
            /// The viewfinder stops before both the black notch and mousepad.
            /// `PreviewLayout` owns the same geometry used by the guides.
            let cameraWidth = previewFrame.width
            let controlSurfaceFrame = CGRect(x: proxy.size.width - rightControls, y: 0,
                                             width: rightControls, height: proxy.size.height)
            let controlSurfaceLeading = controlSurfaceFrame.minX
            /// + / Record / − are centered on this exact 160-point mousepad.
            let captureCenter = CGPoint(x: controlSurfaceFrame.midX, y: controlSurfaceFrame.midY)
            /// Matching circles at the top/bottom of the thumb rail use a
            /// slightly smaller vertical inset, leaving more breathing room
            /// around the centered Record column.
            let railAccessoryDiameter: CGFloat = 41
            let railEdgePadding = (rightControls - railAccessoryDiameter) / 2
            let railVerticalEdgePadding = railEdgePadding * 0.75
            let flipAccessoryY = railVerticalEdgePadding + railAccessoryDiameter / 2
            let colorAccessoryY = proxy.size.height - railVerticalEdgePadding - railAccessoryDiameter / 2
            // 16:9 is shown as a true edge-to-edge preview crop: the camera
            // image fills the whole rounded viewport, with no blurred guide
            // bands or leftover edges. This changes preview only, not output.
            let viewportAspect = cameraWidth / max(1, proxy.size.height)
            let ratioPreviewZoom: CGFloat = !portrait && ratio == .sixteenNine
                ? max(1, ratio.value / viewportAspect) : 1
            ZStack {
                // A physical black notch at the leading edge. It is outside
                // the live viewport, matching the space reserved on the right.
                if !portrait {
                    Color.black
                        .frame(width: leadingNotch, height: proxy.size.height)
                        .position(x: leadingNotch / 2, y: proxy.size.height / 2)
                        .allowsHitTesting(false)
                }
                viewfinder
                    .scaleEffect(ratioPreviewZoom)
                    .frame(width: cameraWidth, height: proxy.size.height)
                    .overlay {
                        if !camera.focusAuto {
                            Text("PEAK")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.red.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.28), in: Capsule())
                                .padding(10)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        if camera.exposureLocked {
                            // AE is a direct target gesture, not a second
                            // numeric ruler. Up/right raises it; down/left lowers it.
                            let targetSize = 44 * exposureTargetPulse
                            let halfSize = targetSize / 2
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.yellow, lineWidth: 1.5)
                                .frame(width: targetSize, height: targetSize)
                                // Keep the visual square precise, but give a
                                // thumb a forgiving transparent touch area.
                                .padding(28)
                                .contentShape(Rectangle())
                                .position(x: min(cameraWidth - halfSize, max(halfSize, exposureTarget.x * cameraWidth)),
                                          y: min(proxy.size.height - halfSize, max(halfSize, exposureTarget.y * proxy.size.height)))
                                .highPriorityGesture(DragGesture(minimumDistance: 4)
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
                                        if exposureTargetDragStartBias == nil {
                                            exposureTargetDragStartBias = camera.exposureBias
                                            exposureTargetLastStep = 0
                                        }
                                        // Slide directly on the target: every 18 points changes
                                        // exposure by 0.1 EV. This makes a long upward/downward
                                        // drag feel continuous rather than acting as one button.
                                        let step = Int((primary / 18).rounded(.towardZero))
                                        guard step != exposureTargetLastStep,
                                              let startBias = exposureTargetDragStartBias else { return }
                                        exposureTargetLastStep = step
                                        camera.setExposureBias(startBias + Float(step) * 0.1)
                                    }
                                    .onEnded { drag in
                                        exposureTargetDragStartBias = nil
                                        exposureTargetLastStep = 0
                                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                                            exposureTargetPulse = 1
                                        }
                                    })
                                .accessibilityLabel("Locked exposure target")
                                .accessibilityHint("Swipe up or right to raise exposure. Swipe down or left to lower exposure.")
                        } else if let target = focusTarget {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(.yellow, lineWidth: 1.5)
                                .frame(width: 44, height: 44)
                                .position(x: min(cameraWidth - 24, max(24, target.x * cameraWidth)),
                                          y: min(proxy.size.height - 24, max(24, target.y * proxy.size.height)))
                                .allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: portrait ? 0 : 22, style: .continuous))
                    .position(x: previewFrame.midX, y: proxy.size.height / 2)
                CompositionOverlay(safeLeft: orientation.windowSafeAreaInsets.left, safeRight: orientation.windowSafeAreaInsets.right,
                                   adjustmentExpanded: adjustmentExpanded, rightControls: rightControls,
                                   leadingNotch: leadingNotch,
                                   framingEnabled: preferences.framingGuide, ratio: ratio, grid: grid, gridDensity: gridDensity, levelEnabled: levelEnabled,
                                   roll: camera.levelRoll, pitch: camera.levelPitch, levelIsCentered: camera.levelIsCentered, isPortrait: portrait)
                    .animation(.spring(response: 0.34, dampingFraction: 0.9), value: ratio)

                // Draw the mousepad above the preview and its composition
                // guides. The viewport no longer underlaps it, but rendering
                // this surface last keeps the boundary visually unambiguous.
                if !portrait {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(InCamTheme.graphite.opacity(0.96))
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(.white.opacity(0.10), lineWidth: 1)
                        }
                        .frame(width: controlSurfaceFrame.width, height: controlSurfaceFrame.height)
                        .position(x: controlSurfaceFrame.midX, y: controlSurfaceFrame.midY)
                        .allowsHitTesting(false)
                }

                if adjustmentExpanded || focusInspector || exposureInspector || (AppFeatureAvailability.cameraColors && colorDockExpanded) || cameraColorProfilesOpen || cameraColorEditorOpen || audioInspectorOpen || showGridChoices || showRatioChoices || showFormatChoices || showScopeChoices || sceneScopeFocused || colorWheelExpanded || colorWorkspaceOpen {
                    transientControlsDismissalLayer(cameraLeft: previewFrame.minX, cameraWidth: cameraWidth, height: proxy.size.height)
                }

                mainCameraOverlay(previewFrame: previewFrame, portrait: portrait, leftInset: leftInset)

                if !portrait {
                    // Keep the exposure column on the camera preview's right
                    // side, then center it vertically within that preview.
                    statisticsRail
                        .frame(width: 64)
                        .position(x: previewFrame.maxX - 36, y: previewFrame.midY)
                        .zIndex(5)
                }

                elapsedReadout
                    .position(x: previewFrame.midX,
                              // Landscape: 12-point timecode's visual top is
                              // on the Audio card's y = 9 top edge, rather
                              // than centered through that 34-point card.
                              y: previewFrame.minY + (portrait ? max(24, orientation.windowSafeAreaInsets.top + 22) : 16))
                    .allowsHitTesting(false)
                    .zIndex(4)

                // The Grid icon opens two adjacent, one-value controls.
                // Tapping either advances it through Settings' saved order;
                // it never exposes a stack of every possible value.
                if !portrait && showGridChoices {
                    CompositionCyclingRow(ratio: ratio, grid: grid, levelEnabled: levelEnabled,
                                          cycleRatio: cycleRatio, cycleGrid: cycleGrid,
                                          toggleLevel: { levelEnabled.toggle() })
                        // Grid is now the first upper-left tool. Start this
                        // three-cell row after the button so Ratio, Grid, and
                        // Level never overlap the source button or each other.
                        //
                        // The separate scope selector directly below Format
                        // controls Waveform/Histogram and is not a framing guide.
                        // Start this three-cell
                        // row *after* that button, rather than on top of the
                        // source button.
                        // Anchor the chooser to the Grid tile's top-left
                        // position; its first option begins just after Grid.
                        .position(x: previewFrame.minX + 220, y: previewFrame.minY + 67)
                        .zIndex(8)
                }

                if !portrait && showScopeChoices {
                    SceneScopeChoiceColumn(selection: sceneScopeMode, onSelect: updateSceneScopeFromPicker)
                        // The held scope is the source of this point. The
                        // current selection is the column's center item.
                        .position(sceneScopeMenuLocation ?? CGPoint(x: previewFrame.minX + 190,
                                                                     y: previewFrame.minY + 250))
                        .zIndex(8)
                }

                if !portrait {
                    // A tap reveals the compact profile tray; holding opens
                    // the separate image-recipe workspace. Neither route
                    // turns on live or recorded camera color rendering.
                    ColorWorkspaceLauncher(
                        diameter: railAccessoryDiameter,
                        isExpanded: colorWheelExpanded,
                        onTap: {
                            dismissAdjustment()
                            audioInspectorOpen = false
                            showGridChoices = false
                            showFormatChoices = false
                            showScopeChoices = false
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                                colorWheelExpanded.toggle()
                            }
                        },
                        onOpenWorkspace: {
                            colorWheelExpanded = false
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                colorWorkspaceOpen = true
                            }
                        }
                    )
                    // Color Profiles is the bottom counterpart to the flip
                    // button. Its bottom gap equals the rail's side gap.
                    .position(x: captureCenter.x,
                              y: colorAccessoryY)
                    .zIndex(7)

                    if colorWheelExpanded {
                        ColorProfileTray(onOpenWorkspace: {
                            colorWheelExpanded = false
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                colorWorkspaceOpen = true
                            }
                        }, onDismiss: {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                                colorWheelExpanded = false
                            }
                        })
                        // The profile tray opens toward the image, where
                        // there is room, while the wheel stays on the right.
                        .position(x: controlSurfaceLeading - 64,
                                  y: colorAccessoryY)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(7)
                    }
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
                    // Flip is a full-size circular rail accessory at the top,
                    // opposite the Color Profiles circle at the bottom.
                    CameraFlipControl(diameter: railAccessoryDiameter)
                        .position(x: captureCenter.x, y: flipAccessoryY)
                        .zIndex(7)
                    modeToggle
                        .position(x: controlSurfaceLeading + 28, y: 42)
                    if AppFeatureAvailability.settings {
                        settingsButton
                            // Settings, Record, and Gallery share one fixed
                            // vertical column through the grey control surface.
                            .position(x: captureCenter.x, y: 42)
                    }
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
                        if previewZoomRulerVisible {
                            VerticalZoomPanel { hidePreviewZoomRuler() }
                                .position(captureCenter)
                                .zIndex(4)
                        } else {
                            // This full-size container is the actual mousepad
                            // rectangle. Its child rocker is aligned in local
                            // coordinates, making the + / Record / − column
                            // coincide exactly with the container's centre.
                            ZStack {
                                LandscapeCaptureCluster(onZoomBegin: { dismissAdjustment(); colorDockExpanded = false })
                            }
                            .frame(width: controlSurfaceFrame.width, height: controlSurfaceFrame.height)
                            // Use the measured mousepad centre, not a preview
                            // or screen-edge calculation, for every rocker
                            // control in this column.
                            .position(x: captureCenter.x, y: captureCenter.y)
                                .zIndex(4)
                        }
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
                    } else if AppFeatureAvailability.cameraColors && colorDockExpanded {
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
                    // Custom Colors lives at the lower leading edge of the
                    // image; its launcher is the only persistent color UI.
                    if AppFeatureAvailability.cameraColors {
                        CameraColorProfileLauncher(
                            isDockExpanded: $cameraColorProfilesOpen,
                            onAdd: {
                                guard let slot = nextCustomColorSlot else { return }
                                colorDockExpanded = false
                                dismissAdjustment()
                                colorControls.prepareNewCustomColor(at: slot)
                                colorControls.cameraColorsEnabled = true
                                cameraColorEditorSlot = slot
                                cameraColorEditorOpen = true
                            },
                            onLoad: { slot in
                                colorControls.selectCustomColor(at: slot, savedSlots: colors.quickSlots)
                                colorControls.cameraColorsEnabled = true
                                cameraColorProfilesOpen = false
                            },
                            onEdit: { slot in
                                colorControls.selectCustomColor(at: slot, savedSlots: colors.quickSlots)
                                cameraColorEditorSlot = slot
                                cameraColorEditorOpen = true
                            },
                            onDelete: { slot in
                                colors.deleteQuick(at: slot)
                                if colorControls.loadedCustomSlot == slot {
                                    colorControls.loadedCustomSlot = nil
                                    colorControls.cameraColorsEnabled = false
                                }
                            }
                        )
                            .position(x: previewFrame.minX + leftInset + 48, y: proxy.size.height - 48)
                            .zIndex(6)
                    }
                }

                // Creating a profile is a real page, not a compact camera
                // popover: the reference image and all three HSL bars remain
                // visible without competing with the viewfinder controls.
                if AppFeatureAvailability.cameraColors,
                   cameraColorEditorOpen,
                   let slot = cameraColorEditorSlot {
                    CameraColorProfileEditorPage(controls: colorControls,
                                                  slot: slot,
                                                  isPresented: $cameraColorEditorOpen,
                                                  isDockExpanded: $cameraColorProfilesOpen)
                        .ignoresSafeArea()
                        .zIndex(30)
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
            // Queue saved assist preferences before camera.start(). This lets
            // CameraController attach an enabled scope in its first session
            // transaction rather than beginning preview and reconfiguring it
            // immediately afterward.
            camera.prepareViewfinderStartup(
                scopeMode: sceneScopeMode,
                focusPeakingEnabled: !camera.focusAuto
            )
            updateOutputFraming()
            updateCameraActivity()
            grid = GridMode(rawValue: savedGridMode) ?? .off
            lastGrid = GridMode(rawValue: savedLastGridMode) ?? .thirds
            gridDensity = min(6, max(2, savedGridDensity))
            if AppFeatureAvailability.cameraColors {
                camera.setCameraColorRecipe(colorControls.recipe)
            } else {
                // Keep stored recipes untouched while forcing the active preview path
                // to native, neutral camera output for the paused state.
                colorDockExpanded = false
                camera.setCameraColorsPreviewEnabled(false)
                camera.setCameraColorRecipe(CameraColorRecipe(name: "Paused Camera Colors"))
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--show-controls") { expandedDock = .whiteBalance }
            if ProcessInfo.processInfo.arguments.contains("--show-iso") { controlPage = .iso; expandedDock = .iso }
            if ProcessInfo.processInfo.arguments.contains("--show-shutter") { controlPage = .shutter; expandedDock = .shutter }
            if ProcessInfo.processInfo.arguments.contains("--show-zoom") { openZoom() }
            if AppFeatureAvailability.cameraColors,
               ProcessInfo.processInfo.arguments.contains("--show-colors") { colorDockExpanded = true }
            if AppFeatureAvailability.cameraColors && AppFeatureAvailability.basicColorControls,
               ProcessInfo.processInfo.arguments.contains("--show-saturation") {
                colorControls.selection = "Saturation"
                colorDockExpanded = true
            }
            if AppFeatureAvailability.cameraColors,
               ProcessInfo.processInfo.arguments.contains("--show-color-mix") {
                colorControls.selection = "Color Mix"
                colorDockExpanded = true
            }
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
        .onChange(of: camera.focusAuto) { _, isAuto in camera.setFocusPeakingEnabled(!isAuto) }
        .onChange(of: savedSceneScopeMode) { _, _ in camera.setSceneScopeMode(sceneScopeMode) }
        .onChange(of: preferences.selectedRatio) { _, _ in updateOutputFraming() }
        .onChange(of: preferences.saveFramedOutput) { _, _ in updateOutputFraming() }
        .onChange(of: colorControls.recipe) { _, recipe in
            guard AppFeatureAvailability.cameraColors else { return }
            camera.setCameraColorRecipe(recipe)
        }
        .onChange(of: camera.logModeEnabled) { _, enabled in
            // Do not leave a hidden Saturation/Contrast dial active in Log.
            if enabled && ["Saturation", "Contrast"].contains(colorControls.selection) {
                colorControls.selection = AppFeatureAvailability.basicColorControls ? "Clarity" : "Color Mix"
            }
            if AppFeatureAvailability.cameraColors {
                camera.setCameraColorRecipe(colorControls.recipe)
            }
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
            guard AppFeatureAvailability.cameraColors else {
                camera.setCameraColorsPreviewEnabled(false)
                return
            }
            camera.setCameraColorsPreviewEnabled(expanded)
            if expanded {
                dismissAdjustment()
                openShortcutSide = nil
                shortcutAdjustment = nil
            }
        }
        .onChange(of: cameraColorProfilesOpen) { _, open in
            if open {
                // The circular Add control never shares the right inspector or
                // activates the optional Camera Colors preview renderer.
                colorDockExpanded = false
                dismissAdjustment()
            }
        }
        .onChange(of: controlLayout) { _, _ in expandedDock = nil }
        .onChange(of: scenePhase) { _, _ in updateCameraActivity() }
        .onChange(of: showSettings) { _, _ in updateCameraActivity() }
        .onChange(of: showGallery) { _, _ in updateCameraActivity() }
        .onDisappear { camera.stop() }
        .overlay {
            if AppFeatureAvailability.settings && showSettings {
                settingsDrawer
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showSettings)
        .sheet(isPresented: $showGallery) { SavedMediaGallery() }
        .fullScreenCover(isPresented: $colorWorkspaceOpen) {
            CameraColorEditorView(recipe: colorControls.recipe,
                                  sourceSlot: colorControls.loadedCustomSlot)
        }
        .alert("Camera", isPresented: Binding(
            get: { camera.lastError != nil },
            set: { if !$0 { camera.lastError = nil } }
        )) { Button("OK", role: .cancel) { camera.lastError = nil } }
          message: { Text(camera.lastError ?? "") }
    }

    /// Settings fills the display while keeping a faint live viewfinder behind
    /// the 90% material. Empty space around its tiles dismisses it, avoiding
    /// a competing upward gesture near the system app switcher.
    private var settingsDrawer: some View {
        GeometryReader { proxy in
            SettingsView(onDismiss: { showSettings = false }, backdropOpacity: 0.90)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .accessibilityIdentifier("settings.drawer")
        }
        .ignoresSafeArea()
    }

    /// Keeps the portrait controls, left-side capture stack, and AF/readout
    /// rail out of the already large camera geometry view. Besides making the
    /// screen easier to review, this gives Swift a small unit to compile for
    /// physical devices rather than one monolithic inferred view type.
    // Composes all live-view overlays above the preview using the measured display geometry.
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
                // Keep monitoring controls against the left safe area.
                // Align the entire left tool rail directly with the black
                // notch boundary, rather than leaving an extra inner margin.
                // Match the monitoring rail's leading inset to its top inset.
                // This leaves one deliberate, even safe-area margin instead
                // of a large empty strip beside the notch.
                let railLeading: CGFloat = 9
                // The first monitoring row shares the timer's visual band.
                // A 34-point top row centered on the 26-point timer band.
                let railTop: CGFloat = 9
                leftCaptureToolStack
                    // A fixed top-left frame keeps the Audio launcher locked
                    // in place. Its inspector therefore grows only downward.
                    .padding(.bottom, railTop)
                    .frame(width: previewFrame.width, height: previewFrame.height, alignment: .topLeading)
                    .offset(x: railLeading, y: railTop)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !portrait {
                // AF/MF is an on-screen tool, so it lives at the camera's
                // lower-right corner rather than competing with the readouts.
                previewFocusModes
                    .padding(.trailing, 12)
                    .padding(.bottom, 18)
            }
        }
        .position(x: previewFrame.midX, y: previewFrame.midY)
        .zIndex(4)
    }

    /// The upper-left stack keeps capture monitoring in one left-aligned
    /// column: L/R audio, storage/time, composition controls and scopes.
    private var leftCaptureToolStack: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 24) {
                audioMeterLauncher
                CaptureStatusTile()
            }
            gridPicker
            CaptureFormatToolStack(isExpanded: $showFormatChoices) {
                dismissAdjustment()
                clearFocusTarget()
                showGridChoices = false
                showRatioChoices = false
                showScopeChoices = false
            }
            // Keep ordinary left-side controls fixed at the top. The scope is
            // independently pinned to the preview's bottom-left, so opening
            // it never pushes Audio, storage, Grid, or format controls.
            Spacer(minLength: 0)
            SceneScopeTool(mode: sceneScopeMode,
                           redSamples: camera.sceneScopeRedSamples,
                           greenSamples: camera.sceneScopeGreenSamples,
                           blueSamples: camera.sceneScopeBlueSamples,
                           isExpanded: $sceneScopeExpanded,
                           isCollapsed: $sceneScopeCollapsed,
                           isFocused: $sceneScopeFocused,
                           onTap: activateSceneScope) { location in
                dismissAdjustment()
                clearFocusTarget()
                showGridChoices = false
                showRatioChoices = false
                showFormatChoices = false
                sceneScopeFocused = true
                sceneScopeMenuLocation = location
                showScopeChoices = true
            }
            // Pull the bottom-left monitor away from the rounded viewport
            // corner while retaining its bottom anchor for upward growth.
            .padding(.bottom, 18)
        }
    }

/// Audio is a compact live indicator at rest. Holding it reveals only its
/// quick settings below the meter; the full vertical meter is not repeated.
    private var audioMeterLauncher: some View {
        AudioMeterLauncher(levels: camera.audioLevels, isExpanded: audioInspectorOpen) {
            toggleAudioInspector()
        }
    }

    @ViewBuilder
    private var viewfinder: some View {
        if camera.authorization == .authorized {
            CameraPreview(camera: camera, onFocusHold: { devicePoint, displayPoint in
                camera.focus(at: devicePoint)
                showFocusTarget(at: displayPoint)
            }, onExposureTap: { devicePoint, displayPoint in
                openExposure(at: displayPoint, devicePoint: devicePoint)
            }, onZoomPinch: { scale, finished in
                handlePreviewPinchZoom(scale: scale, finished: finished)
            })
                // Basic recipe controls use SwiftUI's compositor over the
                // native preview layer. The Metal Color Mix view already
                // includes these values through RecipeRenderer, so never
                // apply them a second time while it is active.
                // The Color dock itself is lightweight. Keep these costly
                // per-frame SwiftUI compositors off while its basic renderer
                // is paused, so opening the app does not burden the preview.
                .saturation(AppFeatureAvailability.cameraColors && AppFeatureAvailability.basicColorControls && !camera.selectiveColorPreviewActive && !camera.logModeEnabled ? 1 + colorControls.recipe.saturation : 1)
                .contrast(AppFeatureAvailability.cameraColors && AppFeatureAvailability.basicColorControls && !camera.selectiveColorPreviewActive && !camera.logModeEnabled ? 1 + colorControls.recipe.contrast + max(0, colorControls.recipe.clarity) * 0.20 : 1)
                .blur(radius: AppFeatureAvailability.cameraColors && AppFeatureAvailability.basicColorControls && !camera.selectiveColorPreviewActive ? max(0, -colorControls.recipe.clarity) * 1.4 : 0)
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

    // Builds the top status row containing timer, focus mode and compact exposure readouts.
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
        if camera.shutterAngleMode {
            return CameraExposureDefaults.shutterAngleLabel(camera.shutterAngleDegrees)
        }
        let displaySeconds = camera.exposureSeconds
        let seconds = CameraExposureDefaults.displayDuration(
            for: displaySeconds,
            frameRate: camera.frameRate,
            angleMode: camera.shutterAngleMode,
            supportedRange: camera.capabilities.manualExposureRange
        )
        guard seconds.isFinite, seconds > 0 else { return "—" }
        return CameraExposureDefaults.speedLabel(seconds)
    }

    /// ISO preserves the selected discrete stop. The hardware may meter a
    /// value between stops while Auto is enabled.
    private var isoReadout: String {
        "\(Int(camera.iso.rounded()))"
    }

    // Creates one tappable compact readout that opens its associated adjustment page.
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
                    // Yellow carries the complete Auto state on the compact
                    // camera readout. Manual values stay ivory, so the old
                    // duplicated A / M letters are no longer needed.
                    Text(value)
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(autoState(for: page) ? .yellow : InCamTheme.ivory)
                    Spacer(minLength: 2)
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

    // Reads the correct automation state for an exposure/focus control page.
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
        // Values are the usable information here. Tighter rhythm and a
        // slightly larger type size make WB, tint, shutter and ISO readable
        // without pushing the AF control or capture column.
        VStack(alignment: .trailing, spacing: 4) {
            statistic("WB", "\(Int(camera.temperature)) K", auto: camera.whiteBalanceAuto, page: .whiteBalance)
            statistic("TINT", String(format: "%+.0f", camera.tint / 12), auto: camera.tintAuto, page: .tint)
            statistic("SHUTTER", shutterReadout, auto: camera.shutterAuto, page: .shutter)
            statistic("ISO", isoReadout, auto: camera.isoAuto, page: .iso)
            VStack(alignment: .trailing, spacing: 2) {
                Text(camera.aperture > 0 ? String(format: "ƒ%.1f", camera.aperture) : "ƒ—")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text(camera.aperture > 0 ? "FIXED" : "UNAVAILABLE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(InCamTheme.ivory.opacity(0.42))
            }
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .trailing)
            .opacity(0.42)
            .accessibilityLabel("Lens aperture")
            .accessibilityValue(camera.aperture > 0
                ? String(format: "f %.1f, fixed by this lens", camera.aperture)
                : "Unavailable for the active camera")
        }.buttonStyle(PressScaleStyle())
            .shadow(color: .black, radius: 3, y: 1)
    }

    // Builds one right-aligned camera statistic row that can open the matching dial.
    private func statistic(_ title: String, _ value: String, auto: Bool, page: CameraControlPage) -> some View {
        let isActive = expandedDock != nil && controlPage == page
        return Button {
            let close = isActive
            controlPage = page
            expandedDock = close ? nil : page.dockItem
        } label: { VStack(alignment: .trailing, spacing: 2) {
            // Auto is yellow and Manual is ivory. The scroll/ruler remains
            // the place where a person changes that mode; this rail only
            // reports the result without spending space on A/M labels.
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
        }.frame(maxWidth: .infinity, minHeight: 34, alignment: .trailing).contentShape(Rectangle()) }
        .foregroundStyle(isActive || auto ? .yellow : InCamTheme.ivory)
        .opacity(isActive ? 1 : 0.42)
        .accessibilityLabel(page.title(for: camera.mode)).accessibilityValue(value)
        .accessibilityHint("Open adjustment at the Record button position")
        .accessibilityIdentifier("status.\(title.lowercased())")
        .simultaneousGesture(TapGesture(count: 2).onEnded { resetControl(page) })
    }

    /// Readout and dial double-taps share the same predictable baselines.
    /// The viewfinder itself keeps double-tap for AE Lock and target placement.
    // Restores the selected adjustment page to its intended neutral/automatic state.
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

    // Advances through enabled composition ratios and refreshes any output-framing request.
    private func cycleRatio() {
        guard !camera.isRecording else { return }
        let choices = preferences.ratioShortcuts
        guard !choices.isEmpty else { return }
        let index = choices.firstIndex(of: preferences.selectedRatio) ?? -1
        preferences.selectedRatio = choices[(index + 1) % choices.count]
    }

    // Converts a grid enum into the compact label shown beside the grid button.
    private func gridName(_ mode: GridMode) -> String {
        switch mode {
        case .off: return "Off"
        case .thirds: return "Thirds"
        case .golden: return "Golden Ratio"
        case .spiral: return "Fibonacci Spiral"
        case .diagonals: return "Diagonals"
        }
    }

    // Opens the zoom adjustment ruler and hides unrelated transient controls.
    private func openZoom() {
        controlPage = .zoom
        expandedDock = .zoom
    }

    // Closes the expanded dock/inspector while retaining the camera's current values.
    private func dismissAdjustment() {
        cancelFocusInspectorDismissal()
        focusInspector = false
        exposureInspector = false
        expandedDock = nil
    }

    /// Closes every temporary inspector after an outside double-tap. Keeping
    /// these assignments in a helper avoids an overly complex SwiftUI gesture
    /// closure, which otherwise fails to compile for a physical iPhone target.
    // Clears short-lived overlays such as focus, AE, zoom and temporary pickers after a background tap.
    private func dismissTransientControls() {
        // The scope gets a quicker shrink/fade than the surrounding HUD so a
        // tap on empty preview feels immediately conclusive.
        withAnimation(.easeOut(duration: 0.12)) {
            sceneScopeExpanded = false
            sceneScopeFocused = false
        }
        dismissAdjustment()
        clearFocusTarget()
        colorDockExpanded = false
        cameraColorProfilesOpen = false
        cameraColorEditorOpen = false
        audioInspectorOpen = false
        showGridChoices = false
        showRatioChoices = false
        showFormatChoices = false
        showScopeChoices = false
        sceneScopeMenuLocation = nil
        colorWheelExpanded = false
        colorWorkspaceOpen = false
    }

    /// Audio opens as the only left-side tool inspector. This isolated action
    /// keeps the view-builder closure simple enough for device compilation.
    // Opens or closes the audio inspector while ensuring other expanded controls are dismissed.
    private func toggleAudioInspector() {
        dismissAdjustment()
        clearFocusTarget()
        colorDockExpanded = false
        cameraColorProfilesOpen = false
        showRatioChoices = false
        showGridChoices = false
        showFormatChoices = false
        showScopeChoices = false
        sceneScopeMenuLocation = nil
        colorWheelExpanded = false
        audioInspectorOpen.toggle()
    }

    /// Switches the scene analyser. The controller adds its video-data output
    /// only for Waveform/Histogram; Off removes it again to protect startup
    /// and recording responsiveness.
    private func selectSceneScope(_ mode: SceneScopeMode) {
        savedSceneScopeMode = mode.rawValue
        showScopeChoices = false
        sceneScopeMenuLocation = nil
    }

    /// Taps use one predictable sequence: the folded circle restores the
    /// Histogram, Histogram switches to Waveform, and Waveform returns to
    /// Histogram. Horizontal swipes are not used to enlarge the monitor.
    private func activateSceneScope(fromCollapsed: Bool) {
        sceneScopeFocused = true
        if fromCollapsed || sceneScopeMode == .off {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                sceneScopeExpanded = false
            }
            savedSceneScopeMode = SceneScopeMode.histogram.rawValue
        } else {
            // The scope now sits at the preview's bottom-left. Its bottom
            // anchor stays fixed, so this larger monitor grows right and up.
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                sceneScopeExpanded = true
            }
            savedSceneScopeMode = sceneScopeMode == .histogram
                ? SceneScopeMode.waveform.rawValue
                : SceneScopeMode.histogram.rawValue
        }
    }

    /// While the thumb-held picker is on screen, update the monitor but keep
    /// the picker open and centered at that same thumb location. An outside
    /// tap still dismisses it through the normal transient-control path.
    private func updateSceneScopeFromPicker(_ mode: SceneScopeMode) {
        savedSceneScopeMode = mode.rawValue
    }

    /// A focus target confirms the tap briefly, then fades away without
    /// changing the camera's actual focus mode or point. Any on-screen tool
    /// action also clears it immediately, keeping the composition UI clean.
    // Shows the visible focus target and schedules its UI-only disappearance without undoing focus.
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
    // Delays focus-inspector dismissal briefly so a drag can finish before Record returns.
    private func scheduleFocusInspectorDismissal() {
        focusInspectorDismissWorkItem?.cancel()
        let work = DispatchWorkItem { focusInspector = false }
        focusInspectorDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    // Cancels the pending focus-inspector timeout when the person resumes touching the control.
    private func cancelFocusInspectorDismissal() {
        focusInspectorDismissWorkItem?.cancel()
        focusInspectorDismissWorkItem = nil
    }

    // Sends the selected composition aspect to the controller's output-framing save path.
    private func updateOutputFraming() {
        guard !camera.isRecording, preferences.framingGuide else {
            if !camera.isRecording { camera.setOutputFraming(aspect: nil) }
            return
        }
        let aspect = orientation.interfaceOrientation.isPortrait ? 1 / ratio.value : ratio.value
        camera.setOutputFraming(aspect: aspect)
    }

    // Removes focus-target UI only; it intentionally leaves the lens focus where it was set.
    private func clearFocusTarget() {
        focusTargetDismissWorkItem?.cancel()
        focusTargetDismissWorkItem = nil
        focusTarget = nil
    }

    /// Separate view-builder boundary for the temporary inspector scrim. The
    /// main camera body is intentionally dense, so isolating this gesture
    /// avoids the physical-device compiler timing out while preserving its
    /// single-tap dismissal and double-tap exposure-lock behavior.
    // Defines the transparent viewfinder tap region used to dismiss temporary controls.
    private func transientControlsDismissalLayer(cameraLeft: CGFloat, cameraWidth: CGFloat, height: CGFloat) -> some View {
        Color.black.opacity(0.001)
            .contentShape(Rectangle())
            // Keep this invisible tap catcher inside the live image. A
            // full-screen catcher can otherwise absorb dock/right-pad taps.
            .frame(width: cameraWidth, height: height)
            .position(x: cameraLeft + cameraWidth / 2, y: height / 2)
            .gesture(SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture()).onEnded { value in
                switch value {
                case .first(let tap):
                    guard tap.location.x >= cameraLeft, tap.location.x <= cameraLeft + cameraWidth else { return }
                    openExposure(at: CGPoint(x: (tap.location.x - cameraLeft) / cameraWidth, y: tap.location.y / height))
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
            cameraColorProfilesOpen = false
            showGridChoices = false
            showRatioChoices = false
            focusTarget = nil
            // One explicit toggle: AF returns to continuous autofocus; MF
            // locks the current lens position and opens its thumb ruler.
            if camera.focusAuto {
                camera.setFocus(auto: false, position: camera.focusPosition)
                focusInspector = true
            } else {
                cancelFocusInspectorDismissal()
                camera.setFocus(auto: true)
                focusInspector = false
            }
        } label: {
            HStack(spacing: 3) {
                Text(camera.focusAuto ? "AF" : "MF")
                if !camera.focusAuto {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
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
        .accessibilityHint(camera.focusAuto
            ? "Tap to lock manual focus and open the focus ruler"
            : "Tap for continuous autofocus. While recording, drag vertically on the right control area to adjust manual focus")
        .accessibilityIdentifier("focus.toggle")
    }

    // Locks/repositions AE at the tapped preview point and opens the compact exposure target UI.
    private func openExposure(at point: CGPoint, devicePoint: CGPoint? = nil) {
        exposureTarget = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
        focusTarget = exposureTarget
        dismissAdjustment()
        colorDockExpanded = false
        showGridChoices = false
        showRatioChoices = false
        camera.lockExposure(at: devicePoint)
    }

    /// A completed target drag changes exposure one step, then settles its
    /// continuously-scaled 0.8×...1.5× feedback square back to neutral.
    // Steps the active AE-lock target by the defined EV increment and keeps its UI synchronized.
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
        Button {
            guard AppFeatureAvailability.settings else { return }
            dismissAdjustment()
            clearFocusTarget()
            showSettings = true
        } label: {
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
        Group {
            if AppFeatureAvailability.gallery {
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
        }
    }

    private var modeAndSettings: some View {
        HStack(spacing: 8) {
            modeToggle

            if AppFeatureAvailability.gallery {
                Button { openGalleryOrStopRecording() } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 14)).frame(width: 38, height: 36)
                        .glass(in: Capsule())
                }.accessibilityLabel("Saved photos and videos")
            }

            if AppFeatureAvailability.settings {
                Button { dismissAdjustment(); clearFocusTarget(); showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .frame(width: 38, height: 36)
                        .glass(in: Capsule())
                }
                .accessibilityLabel("Settings")
            }
        }
        .buttonStyle(PressScaleStyle())
    }

    /// Gallery is also a deliberate stop-recording target. This avoids opening
    /// an empty gallery while MovieFileOutput is still finalizing the clip.
    // Opens Gallery when idle, or stops an in-progress recording instead of hiding capture controls.
    private func openGalleryOrStopRecording() {
        if camera.isRecording {
            camera.capture()
        } else if AppFeatureAvailability.gallery {
            showGallery = true
        }
    }

    /// A preview pinch never moves Record. It only borrows that fixed control
    /// slot for the existing zoom ruler, then restores the original +/- rocker
    /// shortly after the gesture finishes.
    // Converts live pinch scale into lens zoom, temporarily replacing Record with the zoom ruler.
    private func handlePreviewPinchZoom(scale: CGFloat, finished: Bool) {
        previewZoomDismissWorkItem?.cancel()
        if previewZoomOrigin == nil {
            previewZoomOrigin = camera.zoom
            previewZoomRulerVisible = true
            dismissAdjustment()
            colorDockExpanded = false
        }
        if let origin = previewZoomOrigin {
            camera.setZoom(origin * scale)
        }
        guard finished else { return }
        previewZoomOrigin = nil
        camera.stopZoomRamp()
        let work = DispatchWorkItem { previewZoomRulerVisible = false }
        previewZoomDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: work)
    }

    // Restores the normal Record layout after pinch zoom and stops any ongoing zoom ramp.
    private func hidePreviewZoomRuler() {
        previewZoomDismissWorkItem?.cancel()
        previewZoomOrigin = nil
        previewZoomRulerVisible = false
        camera.stopZoomRamp()
    }

    /// The camera is released for app backgrounding and when this screen goes
    /// away, but stays warm while an idle person opens InCam's own Settings or
    /// Gallery. That avoids reacquiring the lens every time an internal panel
    /// closes. Opening Settings during an active recording preserves the
    /// previous stop-on-navigation behavior rather than changing movie capture
    /// semantics without an explicit recording workflow.
    private func updateCameraActivity() {
        let settingsVisible = AppFeatureAvailability.settings && showSettings
        let galleryVisible = AppFeatureAvailability.gallery && showGallery
        let cameraVisible = !settingsVisible && !galleryVisible
        let keepWarmForInternalPanel = !camera.isRecording && (settingsVisible || galleryVisible)
        if scenePhase == .active && (cameraVisible || keepWarmForInternalPanel) {
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

    // Chooses the portrait or landscape arrangement for capture, dock and shortcut controls.
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

    // Creates a portrait-safe shortcut arc anchored to the requested screen side.
    private func portraitShortcut(_ side: ShortcutSide) -> some View {
        let actions = (side == .leading ? shortcuts.c1 : shortcuts.c2).enumerated().filter { $0.element != .unassigned }
        let name = side == .leading ? shortcuts.c1Name : shortcuts.c2Name
        return Menu {
            ForEach(actions, id: \.offset) { entry in
                Button(entry.element.rawValue) { activateShortcut(entry.element, index: entry.offset, side: side) }
            }
            if actions.isEmpty, AppFeatureAvailability.settings {
                Button("Assign in Settings") { showSettings = true }
            } else if actions.isEmpty {
                Text("No shortcut assigned")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(actions.count == 1 ? actions[0].element.rawValue : name)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 44)
                .glass(in: Capsule())
        }
    }

    // Cycles grid visibility/mode and persists the chosen composition overlay state.
    private func cycleGrid() {
        let active = GridMode.choices
        let index = active.firstIndex(of: grid) ?? -1
        let next = active[(index + 1) % active.count]
        if next != .off { lastGrid = next }
        grid = next
    }

    // Dispatches a selected shortcut to the matching camera or presentation action.
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

    // Formats a recording duration as HH:MM:SS:FF using the active frame rate.
    private func format(_ interval: TimeInterval) -> String {
        let framesPerSecond = max(1, camera.frameRate)
        let totalFrames = max(0, Int((interval * Double(framesPerSecond)).rounded(.down)))
        let totalSeconds = totalFrames / framesPerSecond
        let frames = totalFrames % framesPerSecond
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
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
                // The red Record control is the geometric center of the
                // charcoal capture rectangle. Plus and minus are the visible
                // zoom affordances immediately above and below the record
                // target; camera flip is a separate full-size rail accessory.
                CamcorderCaptureRocker(onZoomBegin: onZoomBegin)
                .frame(width: 88, height: 260)
            } else {
                ZStack {
                    CaptureButton(size: 70)
                    CaptureAccessory(compact: true, onZoomBegin: onZoomBegin)
                        .offset(y: 76)
                }
                .frame(width: 88, height: 260)
            }
        }
        .frame(width: 88, height: 260)
    }
}

/// The record column's direct front/rear switch. The icon deliberately shows
/// only the two rotating arrows, without the camera glyph used by the old rail.
private struct CameraFlipControl: View {
    @EnvironmentObject private var camera: CameraController
    var diameter: CGFloat = 32

    var body: some View {
        Button { camera.toggleCameraPosition() } label: {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: diameter * 0.58, weight: .semibold))
                .foregroundStyle(InCamTheme.ivory)
                .frame(width: diameter, height: diameter)
                .glass(in: Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.45 : 1)
        .accessibilityLabel("Switch camera")
        .accessibilityValue(camera.isFrontCamera ? "Front camera" : "Rear camera")
        .accessibilityHint("Switches between the front and rear cameras")
        .accessibilityIdentifier("camera.switch")
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
                // Keep the slow +/- affordances legible without competing
                // with Record; they become even quieter while operating.
                .opacity((zooming || slowPressActive) ? 1 : 0.36)
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

/// The readable capture card that anchors the monitoring HUD. Its collapsed
/// state reports the active format; a tap opens only device-supported choices
/// rather than promising modes the active camera cannot use.
private struct CaptureInfoCard: View {
    @EnvironmentObject private var camera: CameraController
    @Binding var isExpanded: Bool
    let onOpen: () -> Void

    private var freeStorageText: String {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let free = values?[.systemFreeSize] as? NSNumber else { return "Storage unavailable" }
        return ByteCountFormatter.string(fromByteCount: free.int64Value, countStyle: .file) + " free"
    }

    var body: some View {
        Button {
            let opening = !isExpanded
            isExpanded.toggle()
            if opening { onOpen() }
        } label: {
            VStack(alignment: .leading, spacing: isExpanded ? 14 : 4) {
                if isExpanded {
                    expandedHeader
                    Divider().overlay(InCamTheme.ivory.opacity(0.16))
                    optionRow(title: "RESOLUTION", values: camera.availableVideoResolutions.map(\.rawValue), selected: camera.videoResolution.rawValue) { value in
                        if let resolution = VideoResolution(rawValue: value) { camera.setVideoResolution(resolution) }
                    }
                    optionRow(title: "FRAME RATE", values: camera.capabilities.frameRates.map { String(format: "%g", $0) }, selected: String(format: "%g", camera.frameRate)) { value in
                        if let rate = Int(value) { camera.setFrameRate(rate) }
                    }
                    optionRow(title: "CODEC", values: camera.availableVideoCodecs.map(\.compactLabel), selected: camera.videoCodec.compactLabel) { value in
                        if let codec = camera.availableVideoCodecs.first(where: { $0.compactLabel == value }) { camera.setVideoCodec(codec) }
                    }
                    optionRow(title: "COLOR SPACE", values: ["SDR", "LOG"], selected: camera.logModeEnabled ? "LOG" : "SDR") { value in
                        camera.setLogModeEnabled(value == "LOG")
                    }
                } else {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("iPhone")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(InCamTheme.ivory.opacity(0.66))
                            Text(freeStorageText)
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                            Text("\(camera.videoResolution.rawValue) · \(String(format: "%g", camera.frameRate)) · \(camera.videoCodec.compactLabel) · \(camera.logModeEnabled ? "LOG" : "SDR")")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(InCamTheme.ivory.opacity(0.62))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 10)
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.yellow)
                    }
                }
            }
            .foregroundStyle(InCamTheme.ivory)
            .padding(isExpanded ? 16 : 12)
            .frame(width: isExpanded ? 420 : 266, alignment: .leading)
            .glass(in: RoundedRectangle(cornerRadius: 18, style: .continuous), emphasized: isExpanded)
        }
        .buttonStyle(.plain)
        .disabled(camera.isRecording)
        .opacity(camera.isRecording ? 0.5 : 1)
        .accessibilityLabel("Capture format and storage")
        .accessibilityValue("\(camera.videoResolution.rawValue), \(camera.frameRate) frames per second, \(camera.videoCodec.compactLabel)")
        .accessibilityHint("Tap to show supported capture choices")
        .accessibilityIdentifier("capture.monitoringCard")
    }

    private var expandedHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(freeStorageText)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Label("iPhone", systemImage: "iphone")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(InCamTheme.ivory.opacity(0.7))
            }
            GeometryReader { proxy in
                Capsule().fill(InCamTheme.ivory.opacity(0.18))
                    .overlay(alignment: .leading) { Capsule().fill(.yellow).frame(width: proxy.size.width * 0.72) }
            }
            .frame(height: 5)
        }
    }

    private func optionRow(title: String, values: [String], selected: String, choose: @escaping (String) -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title).font(.system(size: 8, weight: .medium)).foregroundStyle(InCamTheme.ivory.opacity(0.56)).frame(width: 68, alignment: .leading)
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.system(size: 12, weight: value == selected ? .bold : .regular, design: .rounded))
                    .foregroundStyle(value == selected ? .yellow : InCamTheme.ivory)
                    .onTapGesture { choose(value) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// The user chooses which one concise status is shown in the former format
/// tile. This preference survives relaunches without pretending that a time
/// estimate is accurate before a real active-format bitrate is available.
private enum CaptureStatusDisplay: String, CaseIterable, Identifiable {
    case storage
    case time

    var id: String { rawValue }
    var title: String {
        switch self {
        case .storage: return "Storage Left"
        case .time: return "Time Left"
        }
    }
    var symbol: String {
        switch self {
        case .storage: return "internaldrive"
        case .time: return "clock"
        }
    }
}

private struct CaptureStatusTile: View {
    @EnvironmentObject private var camera: CameraController
    @AppStorage("incam.monitor.status-display") private var selectedRaw = CaptureStatusDisplay.storage.rawValue
    @State private var freeStorageText = "—"
    @State private var showsTapFeedback = false

    private var display: CaptureStatusDisplay {
        CaptureStatusDisplay(rawValue: selectedRaw) ?? .storage
    }

    private var displayedValue: String {
        switch display {
        case .storage: return freeStorageText
        case .time: return estimatedTimeLeft
        }
    }

    /// This is an estimate based on remaining device storage and the selected
    /// format. The actual duration is ultimately determined by the hardware
    /// encoder and scene complexity, neither of which is known before record.
    private var estimatedTimeLeft: String {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let free = values?[.systemFreeSize] as? NSNumber else { return "TIME —" }
        let baseMegabits: Double
        switch camera.videoResolution {
        case .p720: baseMegabits = 5
        case .p1080: baseMegabits = 12
        case .p4K: baseMegabits = 35
        }
        let frameRateFactor = max(0.5, Double(camera.frameRate) / 30)
        let codecFactor: Double = camera.videoCodec == .hevc ? 0.65 : 1
        let seconds = Double(truncating: free) * 8 / (baseMegabits * frameRateFactor * codecFactor * 1_000_000)
        let hours = Int(seconds) / 3_600
        if hours >= 24 { return "\(hours / 24)d \((hours % 24))h" }
        if hours >= 1 { return "\(hours)h \((Int(seconds) % 3_600) / 60)m" }
        return "\(max(1, Int(seconds) / 60))m"
    }

    private func availableStorage() -> String {
        let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let free = values?[.systemFreeSize] as? NSNumber else { return "—" }
        return ByteCountFormatter.string(fromByteCount: free.int64Value, countStyle: .file)
    }

    var body: some View {
        Button {
            selectedRaw = display == .storage ? CaptureStatusDisplay.time.rawValue : CaptureStatusDisplay.storage.rawValue
            withAnimation(.easeOut(duration: 0.1)) { showsTapFeedback = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeIn(duration: 0.15)) { showsTapFeedback = false }
            }
        } label: {
            Text(displayedValue)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(InCamTheme.ivory)
            .lineLimit(1)
            // Storage/time shares the Audio card's top edge. It is not
            // vertically centered inside the 34-point Audio rectangle.
            .frame(height: 34, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(showsTapFeedback ? 1 : 0.42)
        .task { freeStorageText = availableStorage() }
        .accessibilityLabel(display.title)
        .accessibilityValue(displayedValue)
        .accessibilityHint("Tap to switch between storage left and estimated recording time")
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
    var usesOwnBackground = true

    var body: some View {
        content
            .foregroundStyle(InCamTheme.ivory)
            .accessibilityIdentifier("audio.compactInspector")
    }

    @ViewBuilder private var content: some View {
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
            // Keep the optional dBFS reference compact and on one trailing
            // edge instead of rebuilding the vertical meter in this panel.
            Text("0   −12   −24   −48 dBFS")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .foregroundStyle(InCamTheme.ivory.opacity(0.48))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(8)
        .frame(width: 178, alignment: .leading)
        .modifier(AudioInspectorBackground(isVisible: usesOwnBackground))
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

/// Familiar digital-audio meter markings. These are dBFS (not dBu or LUFS):
/// 0 dBFS is the digital ceiling, −6 is close to clipping, and −18 dBFS is a
/// common production reference. The live bars are the real input channels.
private struct AudioDecibelScale: View {
    let height: CGFloat
    private let marks = ["0", "−6", "−12", "−18", "−24", "−36", "−48", "−60"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(marks, id: \.self) { mark in
                HStack(spacing: 3) {
                    Rectangle()
                        .fill(mark == "0" ? .red : InCamTheme.ivory.opacity(0.28))
                        .frame(width: mark == "0" ? 9 : 6, height: 1)
                    Text(mark)
                        .font(.system(size: 7, weight: mark == "0" ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(mark == "0" ? .red : InCamTheme.ivory.opacity(0.64))
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio scale in decibels full scale")
        .accessibilityValue("0, minus 6, minus 12, minus 18, minus 24, minus 36, minus 48, minus 60")
    }
}

/// Resting audio controls are intentionally small. A long press reveals
/// routing and the full meter, avoiding a panel during ordinary framing.
private struct AudioMeterLauncher: View {
    let levels: [Float]
    let isExpanded: Bool
    let onLongPress: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isExpanded {
                // This card intentionally overflows below its fixed 34-point
                // layout slot. The rest of the left tool rail stays still.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(InCamTheme.graphite.opacity(0.90))
                    .frame(width: 178, height: 154)
                    .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), emphasized: true)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            AudioLevelMeters(levels: levels, height: 20, showsChannelLabels: true,
                             orientation: .horizontal, showsTrackBackground: true,
                             trackOpacity: 0.38, usesNeutralMeterColor: true)
                .frame(width: 162)
                .frame(width: 178, height: 34)
            if isExpanded {
                CompactAudioInspector(onClose: onLongPress, usesOwnBackground: false)
                    .offset(y: 34)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // Its allocation remains the slim meter. Expanding is an overlay,
        // not a relayout operation that shifts every control below it.
        .frame(width: 178, height: 34, alignment: .topLeading)
        .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), emphasized: true)
        .zIndex(isExpanded ? 20 : 0)
        .opacity(isExpanded ? 1 : 0.42)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: isExpanded)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onLongPressGesture(minimumDuration: 0.35) {
                let feedback = UIImpactFeedbackGenerator(style: .medium)
                feedback.prepare()
                feedback.impactOccurred()
                onLongPress()
            }
            .accessibilityLabel("Audio input and meters")
            .accessibilityHint("Touch and hold to open input, output, and channel settings below this meter")
            .accessibilityIdentifier("camera.audio")
            .accessibilityAction(named: "Open audio controls", onLongPress)
    }
}

/// Lets the expanded audio controls join their launcher's one continuous glass
/// rectangle instead of drawing a second card with a visible break.
private struct AudioInspectorBackground: ViewModifier {
    let isVisible: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isVisible {
            content.glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), emphasized: true)
        } else {
            content
        }
    }
}

/// Scope display and selection live below the capture-format control. This is
/// a real, visible monitor rectangle rather than a tiny status icon. Its graph
/// is drawn from `sceneScopeSamples`, which the controller clears when Off;
/// it never runs as a hidden per-frame workload.
private struct SceneScopeTool: View {
    let mode: SceneScopeMode
    let redSamples: [Float]
    let greenSamples: [Float]
    let blueSamples: [Float]
    @Binding var isExpanded: Bool
    @Binding var isCollapsed: Bool
    @Binding var isFocused: Bool
    /// `true` means the tap began on the folded circular launcher.
    let onTap: (Bool) -> Void
    /// The global location is passed to the picker so its selected row can be
    /// presented directly beneath the thumb that opened it.
    let onLongPress: (CGPoint) -> Void
    @State private var lastTouchLocation: CGPoint?

    private var scopeWidth: CGFloat { isCollapsed ? 48 : (isExpanded ? 360 : 240) }
    private var scopeHeight: CGFloat { isCollapsed ? 48 : (isExpanded ? 168 : 112) }

    var body: some View {
        Group {
            if isCollapsed {
                // The folded state is intentionally a true circle, not a
                // small rounded rectangle, so it reads as a launcher.
                Circle()
                    .fill(InCamTheme.graphite.opacity(0.92))
                    .overlay {
                        Image(systemName: mode == .waveform ? "waveform.path.ecg" : "chart.bar.xaxis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(mode == .off ? InCamTheme.ivory.opacity(0.58) : .yellow)
                    }
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(InCamTheme.graphite.opacity(0.86))
                    scopeGraphic
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            Text(mode.label)
                                .font(.system(size: isExpanded ? 12 : 9, weight: .medium, design: .rounded))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.down")
                                .font(.system(size: isExpanded ? 11 : 8, weight: .semibold))
                        }
                        .padding(.horizontal, isExpanded ? 16 : 10)
                        .padding(.top, isExpanded ? 13 : 8)
                        Spacer(minLength: 0)
                        if mode == .off {
                            Text("HOLD TO SELECT")
                                .font(.system(size: isExpanded ? 10 : 7, weight: .bold, design: .rounded))
                                .foregroundStyle(InCamTheme.ivory.opacity(0.46))
                                .padding(.bottom, isExpanded ? 16 : 8)
                        }
                    }
                    .foregroundStyle(mode == .off ? InCamTheme.ivory.opacity(0.54) : .yellow)
                }
                .glass(in: RoundedRectangle(cornerRadius: 17, style: .continuous), emphasized: mode != .off)
            }
        }
        // One tap grows toward the rail's bottom-right because the parent
        // keeps the rail's leading/top anchors fixed. The size is 150%.
        .frame(width: scopeWidth, height: scopeHeight)
        // The compact visual is circular; a rectangular hit target keeps the
        // small launcher reliably tappable without changing its appearance.
        .contentShape(Rectangle())
        // A quiet monitor stays visible without competing with active
        // controls; tapping it restores full opacity immediately.
        .opacity(isFocused ? 1 : 0.42)
        .animation(.easeOut(duration: 0.12), value: isFocused)
        .simultaneousGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in lastTouchLocation = value.location })
        .simultaneousGesture(DragGesture(minimumDistance: 18)
            .onEnded { value in
                // A deliberate right-to-left swipe folds the monitor. The
                // compact circle remains at the same rail origin and can be
                // tapped to return to the rectangular compact monitor.
                guard (value.startLocation.x >= scopeWidth * 0.6 || value.startLocation.y <= 28),
                      value.translation.width < -54,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isExpanded = false
                    isCollapsed = true
                    isFocused = false
                }
            })
        .gesture(TapGesture().onEnded {
            let restoringFromCircle = isCollapsed
            withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                isCollapsed = false
                isExpanded = false
            }
            onTap(restoringFromCircle)
        })
        .onLongPressGesture(minimumDuration: 0.35) {
            // Accessibility and synthesized taps may not supply a drag
            // location; using the scope's midpoint is a stable fallback.
            if !isCollapsed {
                isFocused = true
                onLongPress(lastTouchLocation ?? CGPoint(x: 0, y: 0))
            }
        }
        .accessibilityLabel("Image scope")
        .accessibilityValue(mode.label)
        .accessibilityHint("Touch and hold to select waveform, histogram, or off")
        .accessibilityIdentifier("sceneScope.choose")
    }

    @ViewBuilder private var scopeGraphic: some View {
        Canvas { context, size in
            let gridColor = Color.white.opacity(0.13)
            let inset: CGFloat = isExpanded ? 18 : 11
            let top: CGFloat = isExpanded ? 38 : 25
            let bottom: CGFloat = isExpanded ? 24 : 12
            let graph = CGRect(x: inset, y: top, width: size.width - inset * 2, height: size.height - top - bottom)
            for fraction in stride(from: CGFloat(0), through: 1, by: 0.2) {
                var horizontal = Path()
                horizontal.move(to: CGPoint(x: graph.minX, y: graph.minY + graph.height * fraction))
                horizontal.addLine(to: CGPoint(x: graph.maxX, y: graph.minY + graph.height * fraction))
                context.stroke(horizontal, with: .color(gridColor), lineWidth: 0.5)
            }
            for fraction in stride(from: CGFloat(0), through: 1, by: 0.1) {
                var vertical = Path()
                vertical.move(to: CGPoint(x: graph.minX + graph.width * fraction, y: graph.minY))
                vertical.addLine(to: CGPoint(x: graph.minX + graph.width * fraction, y: graph.maxY))
                context.stroke(vertical, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
            }
            guard mode != .off, !redSamples.isEmpty else { return }
            if mode == .histogram {
                drawHistogram(redSamples, color: .red, in: graph, context: &context)
                drawHistogram(greenSamples, color: .green, in: graph, context: &context)
                drawHistogram(blueSamples, color: .blue, in: graph, context: &context)
            } else {
                // A waveform is displayed as an RGB parade: each real channel
                // owns a third of the rectangle, matching video-monitor UI.
                drawWaveform(redSamples, color: .red, in: graph, band: 0, context: &context)
                drawWaveform(greenSamples, color: .green, in: graph, band: 1, context: &context)
                drawWaveform(blueSamples, color: .blue, in: graph, band: 2, context: &context)
            }
        }
        .padding(2)
    }

    private func drawHistogram(_ samples: [Float], color: Color, in graph: CGRect, context: inout GraphicsContext) {
        let width = graph.width / CGFloat(max(1, samples.count))
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let x = graph.minX + CGFloat(index) * width
            let y = graph.maxY - graph.height * CGFloat(sample)
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        context.stroke(path, with: .color(color.opacity(0.9)), lineWidth: isExpanded ? 1.25 : 0.8)
    }

    private func drawWaveform(_ samples: [Float], color: Color, in graph: CGRect, band: Int, context: inout GraphicsContext) {
        let bandWidth = graph.width / 3
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let x = graph.minX + CGFloat(band) * bandWidth + bandWidth * CGFloat(index) / CGFloat(max(1, samples.count - 1))
            let y = graph.maxY - graph.height * CGFloat(sample)
            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        context.stroke(path, with: .color(color.opacity(0.78)), lineWidth: isExpanded ? 1.05 : 0.75)
    }
}

/// Vertical picker shown at the hold location. The active scope deliberately
/// occupies the middle row, which is the same point as the user's thumb.
private struct SceneScopeChoiceColumn: View {
    let selection: SceneScopeMode
    let onSelect: (SceneScopeMode) -> Void

    private var centeredModes: [SceneScopeMode] {
        let modes = SceneScopeMode.allCases
        guard let index = modes.firstIndex(of: selection) else { return modes }
        return [modes[(index + modes.count - 1) % modes.count],
                selection,
                modes[(index + 1) % modes.count]]
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(centeredModes) { mode in
                Button { onSelect(mode) } label: {
                    Text(mode.compactLabel)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(mode == selection ? .yellow : InCamTheme.ivory.opacity(0.66))
                        .frame(width: 72, height: 30)
                        .glass(in: RoundedRectangle(cornerRadius: 10, style: .continuous), emphasized: mode == selection)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(mode.label)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                let modes = SceneScopeMode.allCases
                guard let current = modes.firstIndex(of: selection) else { return }
                // Swiping down advances through the monitor modes; swiping up
                // reverses it. The re-render recenters the new selection.
                let direction = value.translation.height > 0 ? 1 : -1
                onSelect(modes[(current + direction + modes.count) % modes.count])
            })
        .accessibilityIdentifier("sceneScope.options")
    }
}

/// Opens the saved-profile tray without changing camera capture rendering.
/// Holding it opens the independent reference-image Color workspace.
private struct ColorWorkspaceLauncher: View {
    let diameter: CGFloat
    let isExpanded: Bool
    let onTap: () -> Void
    let onOpenWorkspace: () -> Void
    @State private var suppressTap = false

    var body: some View {
        Button {
            if suppressTap {
                suppressTap = false
            } else {
                onTap()
            }
        } label: {
            Circle()
                .fill(AngularGradient(colors: [.red, .purple, .blue, .cyan, .green, .yellow, .red], center: .center))
                .overlay(Circle().fill(.black).padding(diameter * 0.16))
                .overlay(Circle().stroke(isExpanded ? .yellow : .white.opacity(0.78), lineWidth: isExpanded ? 2 : 1.25))
                .padding(3)
                .background(.black.opacity(0.34), in: Circle())
                .frame(width: diameter, height: diameter)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            suppressTap = true
            onOpenWorkspace()
        })
        .accessibilityLabel("Color profiles")
        .accessibilityHint("Tap to open the profile tray. Touch and hold to edit a reference image.")
        .accessibilityIdentifier("cameraColors.workspaceLauncher")
    }
}

private struct ColorProfileTray: View {
    let onOpenWorkspace: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("PROFILES")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.yellow)
            Button("EDIT") { onOpenWorkspace() }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(InCamTheme.ivory)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 20, height: 24)
            }
            .foregroundStyle(InCamTheme.ivory.opacity(0.72))
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .glass(in: Capsule(), emphasized: true)
        .accessibilityIdentifier("cameraColors.profileTray")
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
