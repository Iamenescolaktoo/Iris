# InCam workflow and performance map

This explains the app as it is written today. It does not change camera behavior.

## Direct answer

There is one intentional **0.75-second** startup stage. There is no intentional multi-minute loading timer. If controls are unusable for minutes, the app is stalled, repeatedly restarting a camera session, waiting on iOS hardware, or doing too much work on the main thread.

## Cold launch

1. `InCamApp.swift` creates shared stores and shows `CameraScreen`.
2. `CameraScreen.swift` lays out the preview and calls `CameraController.start()`.
3. `CameraController.swift` checks Camera permission, then uses one serial camera queue to create an `AVCaptureSession`, choose a lens, and attach photo and movie outputs.
4. The session starts so the preview can become usable.
5. After 0.75 seconds, the app configures photo responsiveness, microphone routing, stabilization, supported formats/codecs/FPS, and the audio meter.

The fixed delay in step 5 protects the first preview frame. It should not make the app take minutes to respond.

## Settings and Gallery delay

`CameraScreen.updateCameraActivity()` stops the camera whenever Settings or Gallery is shown. That releases the camera, microphone meter, motion sensor and zoom work. It is resource-safe, but returning requires iOS to resume the camera session. This is the largest repeated-delay trade-off in the current design.

## File map

| File | What it owns |
| --- | --- |
| `CameraController.swift` | Real camera, microphone, lens, focus, exposure, recording and hardware state. |
| `CameraScreen.swift` | Main camera layout, gestures, inspectors, Settings/Gallery visibility. |
| `CameraPreview.swift` | UIKit preview layer and touch gestures. |
| `CameraDock.swift` | Adjustment control views. |
| `CompositionOverlays.swift` | Ratio/grid/level drawing and preview geometry. |
| `PrecisionRuler.swift` | Reusable stepped drag rulers. |
| `SettingsView.swift` | Settings menus and category tiles. |
| `CameraColorEditorView.swift` | Custom Color reference-image editing UI. |
| `CameraColorModels.swift` | Recipe data and Core Image reference rendering. |
| `CaptureModels.swift` | Shared setting and capture data models. |
| `CameraOrientation.swift` | Orientation lock and safe-area information. |
| `ShortcutArc.swift` | Radial shortcut presentation. |
| `Theme.swift` | Colors and glass modifiers. |
| `InCamApp.swift` | App entry point and shared-store injection. |

## Work that can cost time

| Work | Why it exists | When it runs |
| --- | --- | --- |
| Camera permission | Required by iOS | First launch only. |
| Camera session build | Allocates a physical lens and connects outputs | First preview / recovery. |
| 0.75-second staged setup | Prioritizes preview over optional work | Fresh setup. |
| Microphone route | Uses the real input and output route | After preview / resume. |
| Capability scan | Finds valid resolution, FPS, codec and stabilization options | Deferred setup and relevant changes. |
| Camera stop/resume | Saves resources outside viewfinder | Settings/Gallery/background transitions. |
| Camera Colors render | Core Image builds the edited reference image | Only in Camera Colors. |

## Performance boundaries

- The **main thread** draws SwiftUI and handles taps. It must not wait for camera hardware.
- The **camera queue** is one ordered line for AVFoundation work. It avoids unsafe simultaneous session changes.
- Audio meters update five times per second, not at video-frame speed.
- Custom Color rendering runs only in its editor. It is recipe/reference rendering, not proof that HSL affects live or recorded video.

## Optimizations to measure before changing

1. Time `start()` through `AVCaptureSession.startRunning()`.
2. Time capability scans for every physical lens.
3. Cache format results per lens/resolution if scans are slow.
4. Decide whether Settings/Gallery should keep a configured session warm; still stop for background, interruptions and heat.
5. Move Camera Colors preview generation off the main thread and cache a scaled image if editor dragging stutters.
6. Log every `updateCameraActivity()` call to detect accidental stop/start loops.

The `FILE GUIDE`, `STARTUP MAP`, `LIFECYCLE POLICY`, and `PERFORMANCE NOTE` comments point to the exact code locations above.

## Planned CameraController file split

`CameraController.swift` currently owns several distinct jobs. A safe future cleanup can preserve its public API while moving extensions into five clearly named files:

| File | Responsibility |
| --- | --- |
| `CameraController+Session.swift` | Permission, session start/stop, interruption recovery and system pressure. |
| `CameraController+DeviceControls.swift` | Lens selection, zoom, focus, exposure, white balance and level sensing. |
| `CameraController+Capture.swift` | Photo/video capture, timer, rotation and private/Photos saving. |
| `CameraController+Audio.swift` | Audio route, input, gain, channel mode and metering. |
| `CameraController+Capabilities.swift` | Formats, resolution/FPS, codecs, HDR and stabilization support. |

The original `CameraController.swift` stays the shared object used by SwiftUI. This is a file-organization change only: the public calls from the rest of the app should not be renamed, deleted or reordered.
