# InCam change log

This is the plain-language record of completed product changes. It complements `SOURCES.md`, which records technical sources and limitations.

## October 25, 2026

- **Intentional preview gestures:** A normal preview tap now places/updates AE Lock. Touch-and-hold for one second focuses at the held point, preventing CC and other ordinary one-tap controls from being interpreted as focus. The existing double-taps on individual adjustment controls remain their reset actions.
- **AE target feedback:** As the target is dragged, it continuously grows up to **1.5×** for up/right or shrinks to **0.8×** for down/left. Releasing commits the ±0.3 EV step and springs the target smoothly back to its standard size.
- **Moving level reference:** The level overlay now keeps two short horizontal reference bars fixed while the longer middle bar moves horizontally with phone roll. It turns and glows green only when level.
- **Calendar gallery:** InCam Gallery now groups only InCam-made captures into a month calendar. Thumbnail days retain a 5-point gutter on every side and between squares; a count indicates multiple captures on one day.
- **Gallery drill-in and cells:** Pinch in drills from Month to the week under the gesture, then to its specific day; pinch out returns Day → Week → Month. Today has a red ring around its white date. Calendar gutters are now visible white rules, every date/capture remains square and clipped, and the day tile uses the newest InCam capture from that date.
- **Stable shooting dock:** The bottom dock retains its current fixed size across all aspect ratios and recording states. Recording no longer adds any red perimeter or edge glow around the camera image.
- **Independent control states:** White Balance, Tint, Shutter, and ISO now retain their own Auto/Manual indicators. Editing or switching one no longer changes the other three controls' UI state. iOS only offers true continuous auto-exposure for shutter and ISO together; if one is made manual, InCam holds the other control's current hardware value rather than pretending it is independently metering.
- **Physical-lens pinch:** A deliberate pinch on the preview changes one step to the next available physical iPhone lens. It never invokes digital zoom, and pinching beyond the first or last available lens does nothing. The right control pad remains the place for ordinary zoom.
- **CC draft and save:** Camera Colors **+** now opens the next unsaved recipe draft (CC1, CC2, and so on). A slot is created only by pressing **SAVE**; selecting an existing CC continues to load that saved recipe.
- **Stronger Color Mix response:** HSL hue, saturation, and luminance adjustments have a larger—but still bounded—response so green and the other selected color ranges change visibly without requiring extreme values.
- **Direct AE target:** Double-tapping the viewfinder still locks exposure at the selected point, but there is no longer an AE number, ruler, plus/minus control, or separate right-side panel. Swipe the yellow target up or right for a +0.3 EV step and a larger target; swipe down or left for a −0.3 EV step and a smaller target. The target ranges from 70% to 130% of its neutral size, within the lens-supported compensation range.
- **Audio quick controls:** The in-camera Audio inspector is now a narrow column beside the Audio meter rather than a broad panel over the Audio, Grid, and format controls. It contains only Mono/Stereo, Input, and Output. The default system output is shown as muted **None**; an explicitly selected output is bright. Channel-meter detail and gain remain in Settings rather than crowding the framing view.
- **Readout-safe focus and AE:** The trailing WB, Tint, Shutter, ISO, and aperture rail now rejects the viewfinder’s single- and double-tap recognizers. Tapping a readout opens its own control; it no longer moves a yellow focus/AE target underneath.
- **Focus confirmation:** The yellow focus target now fades after 1.25 seconds while the chosen focus point and AF/MF state remain in effect. Opening Grid, Format, Ratio, Audio, Settings, or another temporary tool hides only that confirmation immediately.
- **Front-camera orientation:** Front preview, still capture, and movie connections explicitly mirror after a camera swap, avoiding the inverted selfie preview.
- **Tap-to-focus guidance:** A fixed-focus lens now explains that it cannot accept a focus point and directs the user to a focus-capable Wide lens, rather than implying a generic app failure.
- **Grid choices:** Opening Grid places the Ratio / Grid / Level cycling choices directly beside the Grid button in its row, not beside the separate 4K/format button.
- **Rounded ratio blur:** The inactive ratio area now uses the camera viewport’s continuous rounded contour. The blurred overlay no longer ends as a squared-off rectangle by the right mousepad.
- **Custom Color picker:** Camera Colors now presents transparent square tiles named **CC1**, **CC2**, and so on, plus a square **+** tile. Selecting a CC opens that recipe’s Color Mix palette; **+** creates/selects the next empty CC slot and opens it. The picker has no material background behind the live image.
- **Front-camera reflection:** The front preview now applies its reflection in screen space across the **y-axis** (left/right), after orientation has settled. Capture output is not double-mirrored.
- **Lens restoration:** Switching from rear to front saves the chosen rear lens. Switching back returns to that lens; it falls back to Wide instead of arbitrarily choosing Ultra Wide.
- **Restored shutter stops:** The explicit shutter sequence includes 1/50, 1/100, 1/400, and 1/620, plus intermediate values through 1/8000. The 4K/24 manual baseline remains 1/50.
- **Responsive Audio inspector:** The expanded Audio control is horizontal in landscape and retains a vertical layout in portrait. Its Output route uses compact System/Speaker buttons so text cannot collapse into a vertical column.
- **Horizontal level indicator:** The level overlay is now three horizontal dashes: a longer center dash with two short outer dashes. It does not rotate or drift; when roll is within 0.7°, the center dash turns green and glows.
- **Camera Colors hold:** A completed press-and-hold on Camera Colors now reliably wins over the normal tap action and opens the HSL/Color Mix editor on the right mousepad. An ordinary tap still opens CC tiles.
- **Synchronized shutter display:** The compact Shutter readout and its adjustment ruler now share one nearest-supported preset. Auto metering is still live, but both locations display the same selectable stop instead of disagreeing (for example, 1/40 versus 1/60).
- **Shutter display:** Double-tapping a shutter readout, its dial, or the shutter label switches between **Shutter Speed** and **Angle**. It does not alter the exposure duration or force Auto/Manual.
- **Shutter display memory:** The selected Speed/Angle view remains selected when the app is reopened.
- **ISO stops:** The camera now preserves the requested discrete ISO values, including 125, 160, 640, 1250, 6400, and 8000, when the active lens supports them.
- **Video codec:** HEVC is chosen by default when supported. H.264 and ProRes variants are shown only when the current phone, lens, and session confirm support.
- **Auto readouts:** While Auto is enabled, shutter, ISO, white balance, and tint now follow the physical camera's live metering. Moving any of those controls manually stops its matching automatic updates.
- **Frame-rate shutter pairing:** Launching or choosing a frame rate now deliberately sets the actual manual shutter to its 2× FPS baseline: 24/25 fps → **1/50**, 30 → **1/60**, 60 → **1/120**, and 120 → **1/240**. The explicit shutter list now includes **1/240**, so that value cannot be rounded away by the interface.
- **Two-axis level:** The level guide now remaps Core Motion into the current screen orientation and shows a camera-style, three-bar live marker over a stable center reference. Its longer middle bar and two shorter outer bars move horizontally for roll and vertically for pitch; the full set turns green only when both are level.
- **Front selfie reflection:** The front preview explicitly uses a horizontal mirror (`scaleX: -1`, never a vertical/upside-down transform) after the interface orientation is applied. Saved media remains unmirrored.
- **Responsiveness repair:** Level motion monitoring now runs only while Level is on; audio meter UI updates at five times per second; preview orientation is applied only when orientation or camera position changes; and native preview recognizers no longer cancel SwiftUI button touches. This removes background UI churn that could make controls appear unresponsive.
- **Audio inspector:** Tapping the top-left audio meter now opens its on-camera inspector directly beside the meter. It includes actual L/R tracks, input selection, gain when the microphone supports it, Mono/Stereo preference, and output routing.
- **Capture names:** Private InCam captures can use a 4–5 character folder with sequential names such as `INCAM_ENES_0001.mov`, or a date-based `YYYY-MM-DD` folder and sequence.

## How we will document future work

Every completed behavior or visual change gets a dated entry here. Changes that depend on device capability or external research also get a supporting note in `SOURCES.md`.
