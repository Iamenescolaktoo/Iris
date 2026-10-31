# InCam

InCam is a native iPhone camera prototype built with SwiftUI, AVFoundation, Core Image, Photos, and Core Motion. The live camera is the dominant surface; composition aids and controls are UI-only and never enter captured media.

Design references and preserved attachments: [InCam design sources](SOURCES.md).

## Run

1. Open `InCam.xcodeproj` in Xcode 15.4 or newer (iOS 17 SDK).
2. Select an iPhone running iOS 17 or newer.
3. Set your development team for the `InCam` target.
4. Build and run, then grant camera, microphone, motion, and photo-library permissions.

The simulator presents the complete interface but cannot provide a real camera feed. Photo/video formats, frame rates, zoom range, and exposure ranges are derived from the active physical camera.

## Current implementation

- Native rear-camera photo and movie capture.
- Landscape-first and adapted portrait shooting layouts.
- Video/Photo mode control, a top-centered elapsed timer, and a solid recording-red outline around the full inside edge of the app while recording. This does not change the phone's physical bezel or enter the captured video.
- Aspect-ratio, grid, and horizon overlays never enter captured output. The yellow ratio button expands its alternatives directly below (4:3, 16:9, and 1:1 by default). Settings controls framing-guide visibility and which three choices appear.
- One shared control box for White Balance, Tint, Shutter, ISO, FPS/format, Camera Color, and Zoom; optional anchored box in portrait. Tap a top readout to open it. The old Controls launcher is removed.
- Video mode shows a compact touch-zoom control to the right of Record. Photo mode replaces it, in the same fixed position, with one yellow millimetre button that opens a vertically stacked lens list. Selecting a lens closes the list and updates the button. Real-device values marked ≈ are horizontal 35 mm-equivalent estimates from the active format's field of view, not calibrated manufacturer lens specifications. Simulator choices are explicitly marked DEMO and do not represent installed hardware.
- WB in kelvin, shutter speed, and ISO share one line at the left, with the timer independently centered. Each opens the shared adjustment panel beside Record in landscape, with vertical value adjustment, swipeable setting titles, and a Manual/Auto button.
- Settings → Camcorder zoom toggles between the spring-centered hold-and-slide zoom rocker and direct vertical zoom adjustment.
- In landscape, touching the compact zoom value beside Record expands it into a vertical bar within the same gesture. Slide up/down to zoom; the large central number follows the current value. Release collapses the bar and stops camcorder motion. Recording remains a separate, non-overlapping touch target.
- Swipe the control title (or use the arrows) to change settings. Drag the ruler to adjust only that value; × closes the panel, and a top readout reopens it.
- The mode button displays Manual or Auto and toggles on tap. Double-tapping the title or value area also toggles the mode. Adjusting a value enters Manual; merely opening or switching controls never changes it.
- Orientation lock choices expand directly downward: Portrait, Landscape Left, Landscape Right, or Unlocked. Lock choice persists; orientation is held during recording. Preview and capture output follow the interface orientation.
- C1/C2 shortcut arcs are opt-in in Settings → C1 / C2 assignments. Only assigned actions appear; one action opens directly, while multiple actions use a named group.
- Settings shell and portrait Camera Colors editor with Process → HSL → Film Look ordering.
- Codable recipe persistence, slot replacement, bypass state, selective HSL Core Image rendering, filtered live preview, and matching saved-photo/video rendering.

Physical-device tuning is still required for zoom ramping, shortcut dwell timing, haptics, thermal behavior, and editor gesture thresholds.

## Verification

The shared InCam scheme includes simulator UI tests for category swipes, independent value adjustments, moving/closing the box, orientation lock, the bottom-dock option, zoom stopping on release, and framing visibility. Run Product → Test in Xcode. Actual camera output, including recorded orientation, filtered export, and hardware zoom/lens switching, requires a physical iPhone. Camera Colors are processed in the preview and applied after capture; other Settings rows remain prototype placeholders.
