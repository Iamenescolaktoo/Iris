# Gallery: UI versus functionality

## Current state

Gallery is intentionally **off** through `AppFeatureAvailability.gallery`.
Its prior source remains in `SettingsView.swift` until the Gallery redesign is
approved; no saved media or gallery metadata has been deleted.

## UI elements

- The former right-column gallery button: `photo.on.rectangle`.
- Month screen: previous/next month controls and square week album tiles.
- Week screen: seven square day tiles with five-point gaps/white separators.
- Day screen: square captured-media tiles.
- Detail sheet: still image or video playback with Done control.
- Empty state: “No Saved Media”.

## Functionality

- Reads only InCam-created private media metadata from `incam.private-media.v1`.
- Does not browse the user’s full Photos library.
- Groups captures into month, week and day scopes.
- Uses the first saved media in a week/day as its thumbnail.
- Pinch-in traverses Month → Week → Day; pinch-out returns one level.
- Builds photo thumbnails directly and video thumbnails with `AVAssetImageGenerator`.
- Opens a photo image or an `AVPlayer` video detail view.

## Recommended source split when re-enabled

- `GalleryScreen.swift` — Gallery navigation, empty state and scope transitions.
- `GalleryMonthGrid.swift` — month album UI and month navigation.
- `GalleryWeekGrid.swift` — seven-day UI and pinch navigation.
- `GalleryDayGrid.swift` — media tile grid and day detail selection.
- `GalleryMediaStore.swift` — private media metadata, file URLs and thumbnail generation.
- `GalleryMediaDetail.swift` — photo/video viewer.

This creates feature-named files without mixing Gallery code into Settings.
