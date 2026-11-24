# Settings: UI versus functionality

## UI elements

- Full-screen, 90% opaque Settings surface.
- Two horizontally paged tile grids.
- Page one: My Menu, Video, Audio, Photo, Monitoring and Color.
- Page two: Recording, Focus and Exposure.
- Tile icon, readable title, page dots, detail back button and tap-outside dismissal.
- Camera audio meter icon remains in the left camera tool stack, separate from Settings.

## Functionality

- Video: resolution, FPS, codec, stabilization, HDR and capture naming.
- Audio: opens input/meter/gain/channel/output controls.
- Photo: front-preview mirror, still format and responsive still capture.
- Monitoring: leveler and display-only overlay preferences.
- Recording: folder/prefix/date naming and output choices.
- Focus: autofocus/manual focus behavior.
- Exposure: shutter, ISO, white balance, tint and AE behavior.
- Color: currently presents a disabled Camera Color Studio state; recipe data is preserved.

## Recommended source split

- `SettingsHome.swift` — paged tile-grid home and dismiss behavior.
- `SettingsCategoryDetail.swift` — category navigation shell and common settings rows.
- `SettingsVideo.swift`, `SettingsPhoto.swift`, `SettingsMonitoring.swift` — category-specific UI.
- `SettingsRecording.swift`, `SettingsFocus.swift`, `SettingsExposure.swift` — capture-control settings.
- `SettingsAudio.swift` — audio category entry only.
- `CameraAudioBox.swift` — the camera-screen meter icon and compact audio inspector.
- `CameraAudioSettings.swift` — meter display, input picker, gain, mono/stereo and output controls.

This leaves Settings as a navigation feature rather than one oversized file.
