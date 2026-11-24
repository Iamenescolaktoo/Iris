# Camera audio box: UI versus functionality

## UI elements

- Compact L/R meter icon below Grid in the camera’s left tool stack.
- Tap target that opens the compact audio inspector.
- Input route selector.
- Mono/Stereo selection.
- Gain control when the selected iPhone input supports it.
- Output route display/selection.

## Functionality

- Uses actual `AVCaptureMovieFileOutput` audio channel power levels.
- Shows empty tracks for unavailable channels; it never creates fake meter data.
- Uses `AVAudioSession` for available inputs, gain, channel count and output route.
- Disables unsafe input/gain route changes while recording.
- Updates meter UI at five Hz, not on every video frame.

## Proposed file ownership

- `CameraAudioBox.swift` — camera-screen icon and compact inspector placement.
- `CameraAudioMeters.swift` — reusable vertical/horizontal meter rendering.
- `CameraAudioControls.swift` — route, gain, mono/stereo and output controls.
- `CameraController+Audio.swift` — AVAudioSession and capture-channel hardware operations.
