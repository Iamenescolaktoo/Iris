# InCam design sources

The user's reference files for InCam's camera controls, touch gestures, and interaction design. Copies are preserved under `Sources/Attachments`; the originals in Downloads are unchanged. Added October 10, 2026.

## Capture resilience and responsive photos — October 31, 2026

- [Apple: Responding to capture-session interruptions](https://developer.apple.com/documentation/avfoundation/avcapturesession/wasinterruptednotification) and [runtime errors](https://developer.apple.com/documentation/avfoundation/avcapturesession/runtimeerrornotification) inform InCam’s interruption/recovery observer. It resumes only while the app has an active camera screen.
- [Apple: system pressure state](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systempressurestate-swift.property) informs the heat policy. At serious pressure InCam reduces only the optional Camera Colors preview cadence; it does not pretend the camera is still healthy at shutdown pressure.
- [Apple: preferred video stabilization mode](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/preferredvideostabilizationmode) requires checking the active video connection. Modes are therefore device/format dependent and may add latency.
- [Apple: responsive photo capture](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isresponsivecaptureenabled) and [Zero Shutter Lag](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/iszeroshutterlagenabled) support the opt-in fast-still mode. It is capability-gated and deliberately does not enable deferred photo delivery because deferred final output is Photos-library based while InCam Gallery is private app storage.
- [Apple: Camera capture events](https://developer.apple.com/documentation/avkit/avcaptureevent) inform the iOS 18+ hardware capture-button integration. This is not a promise that every iPhone has Camera Control.
- [Apple: `isVideoMirrored`](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/isvideomirrored) specifies connection-level horizontal mirroring and requires capability checks. InCam intentionally leaves its front-camera connections unmirrored and applies the user's requested two-axis transform only to live preview surfaces. Saved media does not receive that presentation-only transform.
- Ratio guides are normally non-destructive. The optional **Save output in selected ratio** control is an InCam post-capture center crop, documented in the app so it is never confused with a camera-sensor mode or a promise that changing a guide mid-recording changes an existing clip.
- [Prism](https://github.com/Luminoid/Prism) separates an actor-isolated capture session from a main-actor UI facade. [Lumen Camera](https://github.com/Irenapoghosian/lumen-camera) keeps capture configuration on a private serial queue and discards late filter frames. InCam applies the relevant startup lesson without importing either project: establish the basic session first, defer optional audio/photo tuning, and activate GPU Camera Colors only on demand. Both repositories are MIT-licensed references; no source code was copied.
- [Cambrian CameraKit](https://github.com/Shreeyak/cambrian-ios-camera) reinforces the staged-lifecycle approach: visible capture starts first, then optional work follows only while the viewfinder remains active. InCam cancels delayed optional setup when the viewfinder closes.
- Prism's [`PRMLevelIndicatorView`](https://github.com/Luminoid/Prism/blob/main/Sources/PrismUI/Components/PRMLevelIndicatorView.swift) informs the level math: projected Core Motion gravity, `atan2`, a 60 Hz motion queue, 0.15 exponential smoothing, cardinal-orientation snapping, and a 1°/1.5° entry/exit hysteresis threshold. InCam reimplements those ideas in SwiftUI rather than importing Prism or copying its UIKit source.
- [Lumen Camera](https://github.com/Irenapoghosian/lumen-camera) and [HorizonCamera](https://github.com/Eabusham2/HorizonCamera) both keep preview orientation/mirroring at the capture-connection layer. InCam keeps the data connections explicitly unmirrored; its deliberate live-only two-axis front-preview transform is user-directed and requires physical-device validation across interface rotations.

## Source list

| Source | Use in InCam | Review status |
| --- | --- | --- |
| [Touch Xamarin 2 Hours.pdf](Sources/Attachments/Touch%20Xamarin%202%20Hours.pdf) | Josh Clark's touch-design slides; thumb comfort and placement. | PDF pp. 33-35 reviewed; not a full-document review. |
| [Movement and Music Gestural Interfaces.pdf](Sources/Attachments/Movement%20and%20Music%20Gestural%20Interfaces.pdf) | Supplied excerpt from Dan Saffer's Designing Gestural Interfaces; discoverability and feedback. | PDF pp. 32-34 (printed pp. 19-21) reviewed. |
| [Microinteractions.pdf](Sources/Attachments/Microinteractions.pdf) | The supplied file is a Bookey summary, not the full original book. Modes, feedback, and cancellation. | PDF pp. 31-32 reviewed as a secondary source. |
| [Designing for Emotion 2011.pdf](Sources/Attachments/Designing%20for%20Emotion%202011.pdf) | Aarron Walter; useful, reliable, usable interactions precede delight. | PDF p. 15 (printed p. 7) reviewed. |
| [Camera workflow screen recording](Sources/Attachments/ScreenRecording_10-10-2026%2009-21-57_1.MP4) | Primary visual/behavioral reference for the camera workflow and camcorder-style zoom. | Zoom sequence inspected previously; rechecking against the latest request. |

## Current design requirements from the user

- Keep one highlighted circular ratio button at the top; its alternatives expand below it.
- Use an Apple-style glass visual treatment; distinguish an iOS 17 material-based treatment from native Liquid Glass available with newer Apple SDKs.
- Use the supplied recording as the camera-workflow reference, especially the zoom interaction.
- Landscape Video zoom uses separate small +/− circles above and below Record. A vertical drag dims Record temporarily and shows the current zoom; release stops the ramp and restores the recording tap. No phone-tilt behavior is implemented.
- Photo mode shows a millimetre lens selector in the same accessory position used by Video zoom. Its alternatives expand down, not sideways.
- Orientation choices expand down; opening them does not change orientation.
- The exposure/white-balance mode button displays the current state, Manual or Auto, without a checkmark. Tapping toggles that state.
- Center the elapsed timer inside the camera preview's top edge for every ratio, not at the phone screen's center. While recording, outline the entire inside edge of the app in the same red as Record; the physical hardware bezel cannot change color.
- Custom buttons stay optional.
- Treat the PDFs as reference material, not as instructions that override the user's requested app behavior.

## Source grounded interaction decisions

Updated October 11, 2026. These are InCam design applications of the references, not claims that a book specifies this exact camera layout. The user supplies the downward direction and the shared Video/Photo position.

| InCam decision | Source passage | Application |
| --- | --- | --- |
| Show available ratios, lenses, and orientations instead of silently cycling them. | Gestural Interfaces, printed pp. 19-21: discoverability, response to actions, and avoiding confusing errors. | Opening reveals named choices without changing the setting. Choosing one updates the highlighted value and closes the choices. |
| Label the current state Manual or Auto. | Bookey Microinteractions summary, PDF p. 31: modes change how actions behave and can confuse users. Gestural Interfaces, printed p. 20: acknowledge actions visibly. | Two clear state names replace an ambiguous Auto action label and AUTO checkmark. Dragging values enters Manual; the state label changes. |
| Touch expands zoom; releasing collapses and stops it. | Bookey Microinteractions summary, PDF p. 32: spring-loaded modes last while the activating physical action is held. | A single continuous touch controls the temporary zoom state. This is an application of a secondary-source description, not a quotation from the full book. |
| Keep frequently used controls close to the thumb with stable placement. | Touch slides, PDF pp. 33-35: thumb reach has a comfort zone. | One accessory position is shared by Video zoom and Photo lens selection. The slides illustrate portrait grips; landscape placement still needs device testing. |
| Verify selection, cancellation, and recording safety before further decoration. | Designing for Emotion, printed p. 7: functionality, reliability, and usability underpin delight. | Keep orientation changes disabled while recording, preserve chosen values, and stop zoom on release or interruption. |
| Make recording state unmistakable. | Gestural Interfaces, printed p. 20: timely visible feedback acknowledges an action. | A top-centered timer and a steady full-screen red outline follow the user's placement/color request. The source supports feedback, not this exact geometry or red specification. |

## Landscape revision — October 11, 2026

The user's latest placement request supersedes the earlier inside-preview cards: left-side WB/shutter/ISO/focus readings now open one adjacent vertical adjustment rail. All readings remain visible; disclosure chevrons, a selected highlight, and pressed feedback make their interaction visible. Record, zoom, orientation, and Settings occupy the right outside margin. The rounded preview retains the ratio selector. Video is the default; Photo mode is opt-in through Settings.

This applies Gestural Interfaces printed pp. 19-20 (PDF pp. 32-33): discoverability and visible feedback; and Designing for Emotion printed p. 7: usable, reliable behavior before decoration. The sources support these principles, not the precise left/right placement, which comes from the user. AF/MF remains specific to focus; shutter and ISO share exposure Auto/Manual. Hardware behavior and touch comfort still require device testing.

### Follow-up: centered dials and dismissal

Correction: the inside-preview dial and lower-corner rearrangement were rejected. Restore the previous outside layout: statistics and the active adjustment dial in the left margin; Record and zoom together in the right margin. No adjustment dial or zoom control covers the preview. Keep the requested small category label, centered numeric value, upward-increase gesture, and tap-outside dismissal without an X. Orientation remains configurable in Settings, with no camera-screen lock button. These precise placements are user-directed; the references support discoverability, visible feedback, and reliable behavior, not an inside-preview placement.

### Collapsible dial space

Latest spacing correction: zoom sits to the left of Record in the right outside margin. The left adjustment rail reserves space only while open; dismissing it lets the preview grow leftward, keeping its selected aspect ratio and its right edge fixed. Statistics stay visible. The short size transition respects Reduce Motion. This is a user-directed placement refinement applying the references' visible-feedback and stable-control principles; it is not a claim that the books prescribe these measurements.

### Bottom color dock — first review pass

The user requested the camera-statistics flow laid out horizontally for personal color editing. A divided bottom rectangle now exposes Tint, Saturation, Contrast, and Color Mix. Selecting a section reveals horizontal adjustment; Color Mix identifies one of eight named color ranges and its Hue/Saturation/Luminance axis. Draft settings persist separately from saved slots; saving a slot uses the existing explicit replacement sheet. The preview reserves space above the dock, and zoom remains left of Record, outside the preview.

Source rationale: Gestural Interfaces printed pp. 19–20 supports discoverable choices and visible selected-state feedback; Designing for Emotion printed p. 7 supports being clear about functional limits before decoration. The precise dock layout comes from the user. Important limit verified in code: HSL is currently only represented in recipe data, and no recipe processing is connected to live capture. The dock therefore says “Not applied to live video.” This pass implements recipe editing and persistence, not working LUT import, a selective-color mask, live grading, or graded recordings.

### Bottom dock refinement

The color dock now reveals or covers the bottom of the existing camera image with a top-aligned mask. Its height is not an input to the preview's layout, so opening it does not resize the camera layer, shift the image, or change zoom. Left-side adjustments retain their separate resizing behavior. The full-width “Color Recipe” header is removed; a compact trailing options button retains “Save Color…” and the live-processing limitation. This follows the user's corrected save intent, while maintaining the references' discoverability and honest-feedback principles.

### Slim dock and hide/reveal

The dock is now 48 points collapsed and 128 expanded, with spaced separators and a compact color/axis row. The adjustment track is two points with a smaller thumb, while its gesture area remains taller. A downward vertical gesture hides the dock; a bottom handle supports swipe-up or tap to reveal. Horizontal adjustment gestures are kept separate from hiding. Oversized aspect ratios fit above the compact dock with a ten-point gap; further expansion only masks the bottom, rather than repeatedly resizing the image. The user's requested compactness is balanced against the touch and discoverability principles already cited. Touch testing on a physical device is still required.

### Compact zoom and preview-relative timer

Latest user correction: landscape zoom shares a narrow grey surround with Record: plus above, minus below. Drag upward to zoom in or downward to zoom out. During this gesture, Record dims and the current zoom appears in the center; release restores the recording tap. The record target does not move or disappear. Releasing or interrupting the gesture stops the zoom ramp. This applies the previously cited spring-loaded interaction and visible-feedback principles; the exact placement is user-directed. Physical touch behavior still requires testing.

The timer now follows the preview rectangle's top center instead of the screen's center. Each selected ratio is centered in the available space between the outside control rails and the compact bottom dock. This supersedes the earlier right-edge anchoring. Expanding the color dock still masks only the bottom of the image. The references support stable, understandable feedback, not this precise geometry.

A separate composition-grid picker offers Off, Thirds, Golden Ratio, and Diagonals. Following the user's correction, it matches the circular ratio selector: the current grid has its own miniature icon and alternatives open downward. Fibonacci is removed from the choices, including custom shortcuts. The latest Diagonals correction is exactly one X plus one centered vertical/horizontal cross, with no extra diagonal lines. Guides are clipped to the rounded preview. Grid selection does not change the aspect ratio.

### Recipe bookmark star

The dock's trailing ellipsis is replaced by a small star in the same row. A filled yellow star means the current adjustment values match a saved recipe; changing an adjustment makes it outlined, and restoring the values restores the highlight. Recipe names and IDs do not determine this state. Tapping opens saved recipes and an explicit named-slot save flow; existing recipes are not silently overwritten.

The picker and save screen show an actual processed demo color chart, or a photo the user selects through the system photo picker. The picker states the rendering limits: tint, global saturation/contrast, sharpening and grain are previewed; HSL/Color Mix and clarity are not yet rendered, and recipes do not affect live or recorded video. This applies Gestural Interfaces' visible-feedback principle and Designing for Emotion's reliability principle. The compact star and its placement come directly from the user. Physical touch behavior and full color processing remain separate follow-up work.

### Paged right-side adjustments and rainbow selection

The latest review replaces the tall grey record capsule with separate small plus/minus circles, retaining larger invisible touch areas. The bottom color dock has four page dots and larger category/value labels. Swiping the dock or the right-side category heading changes Tint, Saturation, Contrast, or Color Mix without changing their values. The active adjustment remains open until an outside tap; dragging its ruler changes only the value. During recording a separate Stop target remains available below this inspector.

Color Mix now has a rainbow strip beside the value ruler, selecting the eight supported color ranges without a row of tiny named swatches. Its secondary heading and three dots switch Hue, Saturation, and Luminance; the active title stays above the ruler. The rainbow selects existing discrete color ranges, not arbitrary sampled pixels. Focus shows Near/Far with a scrolling ruler rather than a misleading percentage; these are relative lens-position endpoints, not measured distances. These are user-directed applications of the references' discoverability, visible-feedback, and mode-separation principles. Recipe preview/live-capture limitations stated above still apply.

### Smaller capsules, long-press custom colors, and dynamic controls

The user's next review removes the star and focus emoji. The bottom dock and camera/color adjustment panels use smaller glass capsules; WB, shutter, ISO, and focus keep their existing outside-preview positions. The focus ruler has a plain center marker, not emoji or a percentage. Dock chevrons and duplicate page dots inside the adjustment panel are removed. Color Mix has stacked group/parameter titles, abbreviating Hue/Saturation/Luminance to HUE/SAT/LUM. The bottom dock retains its four page indicators.

Holding the dock for 0.6 seconds opens Custom Colors; an accessibility action exposes the same command. Fresh installs start with Custom Color #1 through #10. Existing recipes are preserved, unchanged built-in starter names migrate to numbered names, and a backup of previous saved data is kept. Double-tapping a recipe name opens renaming; Add Color creates further slots. Saving still explicitly names the target before replacing its settings. This applies the references' error-prevention and continuity principles; the hidden hold gesture is specifically requested by the user and is documented here as a discoverability tradeoff.

Ratio and Grid are now in one vertical stack at the preview's upper left, with Grid below Ratio. Expanded choices participate in layout, pushing following controls downward; only one selector is expanded at a time. These placements and proportional changes are directly user-specified.

### Stable dock width and bounded page swipes

Opening a camera or color inspector keeps the bottom dock's width and horizontal position stable. Tapping Tint, Saturation, Contrast, or Color Mix now selects that category and opens its adjustment on the right, without changing its value. Swipes still change one page at a time, with hard stops at Tint and Color Mix rather than wrapping. Holding the dock opens Custom Colors. Camera and color inspectors are mutually exclusive: opening either closes the other.

WB, shutter, and ISO use transparent 64-point-wide inspectors with a 112-point ruler whose center aligns exactly with Record's center. Their small transparent readouts stack vertically directly below AF/MF in the camera rectangle's top-right corner. The existing 8-point labels, 10-point values, and 44-point minimum tap heights are retained. The timer remains centered at the top. Dragging a camera ruler enters manual control; Auto below restores automatic control. Camera and color inspectors remain mutually exclusive. Color-circle selection is swipe-only, with an accessibility adjustment action, not individual tap targets. These are user-directed interaction corrections; hardware/touch validation is still required.

### Floating dock and left aligned camera

The bottom dock is centered left-to-right across the whole landscape phone, not the preview. Its right edge defines the camera area's right boundary. Settings, Record, and adjustment dials share a single right-side vertical column. The user explicitly confirmed this dock placement.

The bottom dock has no page dots and is 44 points tall, with a target width of 72% of the safe screen width capped at 520 points. The camera starts at the display's left edge and ends at the dock's right edge, reserving the rest of the right side for thumb controls. The camera viewport fills the display height with no shaded top/bottom strips. The dock floats over this camera area and stays fixed when inspectors open. Its rounded material capsule retains category/value pairs, bounded swipes, and long-press saving. The landscape-only preview uses aspect-fill; restored 16:9, 4:3, and 1:1 choices are thin, left-aligned composition guides over the image, not output encoding or cropping controls.

The outer camera outline is hidden while its layout and ratio/grid guides remain intact. WB/Shutter/ISO values and A/M beneath AF/MF are right-aligned. The right-hand control area uses muted charcoal; the live camera viewport is not tinted. The existing AVCaptureVideoPreviewLayer displays the capture session inside that viewport on an authorized physical iPhone. The Simulator does not provide live camera footage.

### Camera Colors hold and slide

The user supplied [this HSL reference screenshot](Sources/Attachments/HSL-reference-2026-10-11.png) on October 11, 2026. The mixer follows its six color ranges: red, yellow, green, cyan (Aqua), blue, and magenta. At the user's October 15 request, a thin vertical gradient strip replaces horizontal circles. Dragging along it selects a color range directly, with a marker indicating the current range and a wider invisible touch area. HUE, SAT, and LUM form a compact vertical label-only list, with no numbers or Adjust button. Tapping an axis opens its transparent ruler; sideways swipes also enter or leave the dial. Vertical drags on the list select an axis; vertical ruler drags adjust its value. Numeric values appear only inside the active dial. Colored dashes replace continuous bars: spectrum for Hue, gray-to-color for Saturation, black-to-white for Luminance. These are parameter legends, not measured image samples. Existing orange and purple recipe data are preserved. Selective HSL rendering is not yet connected to live preview or recorded video.

### Slow zoom buttons

At the user's request, tapping plus or minus changes zoom by 0.1×. Holding repeats that step once per second; release, leaving the screen, or app inactivity cancels repetition. The existing separate camcorder drag interaction remains available. Device zoom limits still apply. This is a user-selected interaction rate, not a camera hardware specification.

### Exposure lock

Double-tapping the preview places a yellow target and locks exposure at that point. The target is now the only AE control: it shows neither a numeric value nor a ruler. A swipe up or right applies a +0.3 EV step and grows the target; a swipe down or left applies a −0.3 EV step and shrinks it. The visual size spans 70% to 130% of neutral, while `AVCaptureDevice` still clips actual compensation to the active lens's supported range. This uses AVCaptureDevice locked exposure and exposure target bias, not a preview darkening filter. [Apple documents bias behavior in locked exposure](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetbias). Actual exposure behavior requires testing on an iPhone; the Simulator only exercises UI state.

### Independent Auto/Manual controls and lens pinch

InCam now tracks Auto/Manual state independently for White Balance, Tint, Shutter, and ISO so an edit to one control does not relabel the other controls. This is a UI and saved-intent distinction: AVFoundation exposes continuous auto exposure as one hardware mode that meters shutter duration and ISO together. When either member is manual, the camera uses custom exposure with the retained current value for the other member; it must not claim a nonexistent independent hardware Auto ISO or Auto Shutter mode. Pinch gestures choose adjacent physical camera inputs only, ordered by their field-of-view estimate. No lens is changed if the selected input is already the widest or tightest option, and pinch does not fall through to digital zoom. This is based on [AVCaptureDevice exposure modes](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuremode) and [AVCaptureDeviceInput](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput).

### Preview gestures, level feedback, and gallery calendar

Preview gestures now distinguish the requested actions: one ordinary tap locks/repositions AE; a one-second hold focuses at the held location. AE adjustment is performed by holding and swiping the resulting yellow target. Its swipe feedback pulses 1.4× for an increase and 0.8× for a decrease before returning to standard size, while the actual camera bias remains constrained by the active device's supported range. The level display uses device-motion roll: two short reference bars stay fixed and the longer middle bar moves horizontally, glowing green when within 0.7 degrees. Gallery remains app-private and now lays InCam captures out in month calendar days, with five-point gutters between and around thumbnail squares. No Photos-library browsing is introduced.

### Neighbor hints on the color dial

The right-side Tint, Saturation, and Contrast dial retains a narrow ruler without its material background or capsule outline. Its central value uses the same position as Record. Camera Colors uses the same active-value anchor, with its thin vertical color selector beside it. Below the ruler, small previews show neighboring settings and their stored values (TINT, SAT, CON, COL), replacing full/half-circle indicators. Only existing neighbors are shown. Horizontal swipes across these previews change one page without modifying values, and navigation stops at either end. The bottom dock has no page dots. These visual choices are requested by the user; they apply the supplied gesture reference's visible-feedback principle, rather than being prescribed by the source. Transparent controls use a subtle text shadow; visibility against real camera footage still needs device review.

The dial's ruler now reserves a fixed clear window around the center value. Tick spacing stays balanced above and below it at positive and negative values, with longer major marks and softer edges. Dragging moves the scale continuously while the numeric adjustment retains its defined increments. A mixed-case title and additional top inset keep long labels away from the curved edge. This corrects the drifting gap and tick overlap shown in the user's screenshot, without changing the dock, page navigation, or value ranges.

### Manual ISO increments

The user requested 100-point increments: 100, 200, 300, and so on. These are an interface choice, not a claim about a universal camera ISO scale. [Apple's ISO documentation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso) and [minimum ISO documentation](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/miniso) establish that supported ISO depends on the active device format. The manual ruler and setter use only whole hundreds within that hardware range. Auto ISO is not rounded. If a format has no whole-hundred value in its range, the control remains at its supported minimum rather than offering an invalid setting.

### Manual shutter limit

At the user's request, the manual shutter dial stops at 1/1500 second instead of exposing the camera's full fastest range. The main dial, custom shortcut, and manual setter share the limit. A slower hardware limit takes precedence; a format whose entire duration range is faster falls back to its slowest supported duration. Automatic exposure remains unchanged. The 1/1500 limit is a user-selected interface preference, not a universal camera standard or a recommended exposure for every scene.

### Tap focus inside the preview

The latest focus request keeps the single AF/MF toggle and restores a transparent manual-focus ruler at the right-thumb position in MF. The ruler has near/far labels and a plain center marker, not a percentage. Switching to AF closes it; opening a camera or color inspector closes it without changing focus mode. The product's two visual groups are image controls and on-screen tools. Focus mode belongs with the tools visually but changes real lens focus, unlike composition grids and ratio overlays. These conventions are saved in `AGENTS.md` for future project tasks.

For landscape video, one 38-point circle with a 44-point tap area sits in the preview's upper-right corner, opposite Ratio and Grid. It displays AF or MF and toggles between them. AF uses continuous autofocus around a tapped subject. MF offers the right-side manual lens-position ruler; after dismissing the ruler, tapping the image can also focus once and hold. A yellow target marks the requested point. If an inspector is open, the first outside tap dismisses it; a subsequent preview tap focuses.

Touch coordinates are converted through the actual preview layer, which accounts for preview sizing and cropping. Focus taps only set the focus point and mode, never exposure. The camera is checked for focus-point and mode support before changing it. This follows [Apple's focus-point API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/focuspointofinterest), [one-shot autofocus behavior](https://developer.apple.com/documentation/avfoundation/avcapturedevice/focusmode-swift.enum/autofocus), and [preview coordinate conversion](https://developer.apple.com/documentation/avfoundation/avcapturevideopreviewlayer/capturedevicepointconverted(fromlayerpoint:)). Real focus acquisition requires physical-iPhone testing; the Simulator validates layout only.

ISO and shutter remain coupled in this implementation. Both labels read the shared exposure mode, and [the custom-exposure API used by the iOS 17 build](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)) fixes both duration and ISO. Independent priority modes have not been implemented; the UI must not label one value automatic while both are locked.

### Compact control scales and shutter presets

The user requested integer Tint, Saturation, and Contrast scales from -7 to +7. These map to the existing normalized recipe range, preserving saved strengths rather than truncating old recipes. Camera Colors replaces the visible Color Mix name. Its active ruler and neighbor previews share the other color dials' center and lower anchors. WB, shutter, and ISO readouts retain their values and A/M states but omit title and chevron lines; accessible control names remain.

AE compensation is limited to -0.3...+0.3 EV, intersected with device support, with 0.1 EV ruler increments. The plus/minus buttons still step by 0.3 EV and stop at the endpoints.

Shutter uses familiar duration presets rather than logarithmic fractional values. A muted Speed/Angle switch exposes angle presets through 360 degrees. Angle is an alternate representation of exposure duration, calculated as duration × frame rate × 360, as documented in [RED's shutter guide](https://docs.red.com/955-0190_v1.4/955-0190_v1.4.1_REV-1.1_RED_PS_KOMODO_Operation_Guide/Content/4_Menus/Image_LUT/Shutter.htm). InCam filters presets to the device-supported range, the user's 1/1500-second manual limit, and one frame's duration in video. Switching representation alone does not alter exposure. Automatic exposure remains free to report non-preset values. Real camera behavior still needs iPhone testing.

## Compact controls and audio update

The October 15 references specify a 56-point horizontal color-selection strip matching the HSL list, smaller degree/percent suffixes, a half-height AE ruler with its value level with the target, trailing-aligned AF and camera readouts, and rounded charcoal controls. These supersede the earlier vertical color strip and independently clamped AE position. Near the top/bottom edges, AE buttons extend inward without moving the value away from the target center. Camcorder drag zoom is always enabled.

Ratios are added/removed from a list; removing all hides the guide and persists across launches. Selected guides are centered in the unchanged wide viewport, with a 60% black mask outside the guide. This is a composition aid, not a recording crop. The catalog offers 16:9, 4:3, 3:2, 1:1, 4:5, 9:16, 1.85:1 and 2.39:1. Previously saved 5:4/7:5 selections remain removable rather than being silently discarded. Sources: [Adobe photography framing](https://blog.adobe.com/en/publish/2016/07/26/the-art-of-directing-your-audience), [Adobe video aspect ratios](https://www.adobe.com/creativecloud/video/discover/aspect-ratio.html), and [Adobe cinematic and vertical formats](https://www.adobe.com/in/creativecloud/roc/blog/video/master-aspect-ratios-easily.html).

Audio has a matching circular button below Grid, vertical channel meters, available microphone selection, hardware input gain where supported, and a read-only output-route name. Meters poll actual capture-channel average power in dBFS at 10 Hz, displayed over −60 to 0 dBFS. No sample signal is fabricated when unavailable. Source selection is disabled during recording. The Simulator has no supported audio capture in this app; microphone permission, route switching, metering, gain and recorded sound require physical-iPhone verification. Live microphone playback, EQ and compression are not implemented. HSL remains recipe-only.

Audio API sources: [Apple input selection](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferredinput(_:)), [input gain capability](https://developer.apple.com/documentation/avfaudio/avaudiosession/isinputgainsettable), and [capture-channel average power](https://developer.apple.com/documentation/avfoundation/avcaptureaudiochannel/averagepowerlevel), checked against the installed iOS 17 SDK headers.

## Five custom color slots

The subsequent orientation correction places left-aligned HUE/SAT/LUM labels beside a vertical adjustment gradient on their right. Drag up to increase and down to decrease. Only the separate color-range selector above remains horizontal; this supersedes the horizontal adjustment gradient described below.

The audio shortcut below Grid now displays compact vertical meter tracks instead of a waveform icon. Tapping the meter opens audio input settings. Empty tracks indicate unavailable input; the separate below-button meter is removed.

The October 15 follow-up uses five initially empty quick slots under CC (Custom Colors). An empty-slot tap saves the current draft; a filled-slot tap loads its recipe into the controls. Tapping the same loaded slot again asks before replacing its saved settings. Cancel preserves the slot. Quick slots persist separately from the existing recipe library, which remains intact. Applying a slot updates recipe settings only; it does not add live or recorded HSL rendering.

Camera Colors shares the other adjustment titles' vertical anchor. Its lower navigation shows ‹ CON and CC ›; the CC page returns through ‹ Camera Colors. HUE/SAT/LUM are right-aligned and choose an always-visible horizontal adjustment gradient. The separate upper strip selects the color range. Hue is a signed shift around that range; saturation runs from gray to the selected hue; luminance runs from black to white. These are adjustment previews, not sampled footage colors.

## October 20 capture and control corrections

Camera Colors now has an actual capture path: a filtered Core Image preview is shown only when the draft has visible adjustments; neutral settings retain the native preview layer. The same recipe is rendered into captured photos and, after recording stops, into a replacement movie before it is saved to Photos. The export preserves the camera's audio track. Selective HSL uses a cached 32³ RGB color cube: each selected range has a soft hue-distance falloff, and Hue, Saturation, and Luminance modify only the matching portion of that lookup table. This is an RGB/HSL approximation, not a log-color pipeline or a calibrated LUT system; physical-device performance and color accuracy still need review.

Grid mode and density now persist as composition preferences. The grid remains an on-screen guide and is deliberately not burned into the saved media. The red recording outline follows the capture viewport only, not the control surface. Horizontal gestures are restricted to the color-range strip and page previews; the separate vertical HSL ruler owns vertical adjustment. The CC navigation is an explicit button so it does not compete with that drag gesture.

Shutter choices now include 1/24 and common exposure-speed steps through 1/1500, filtered against the active format's duration limits. Angle values continue to derive from the current frame rate using shutter speed = 1/(frame rate × 360/angle), following [RED's camera documentation](https://docs.red.com/955-0190_v1.3/955-0190_v1.3_REV-01_2_RED_PS_KOMODO_Operation_Guide.pdf). ISO now exposes the active format's real minimum rather than forcing ISO 100; [Apple documents](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/miniso) that the minimum and maximum ISO values come from that format, and manual ISO is clamped to the same device range.

## October 20 follow-up controls

The bottom Color dock is now centered within the live capture viewport, not the full phone window. Ratio and grid are compact rectangular tap-to-cycle controls; audio uses the same shape and shows two vertical tracks. The meter fill runs green → yellow → red, with red reserved for the top end near clipping. The dock no longer has a downward swipe-to-hide gesture.

The color-range reset returns Hue, Saturation, and Luminance for the selected color only to neutral. On-camera color values are bounded to conservative limits before live rendering to avoid clipped channels. The filtered preview accepts camera-native Y'CbCr buffers, discards late frames, keeps one render in flight, renders a quarter-size image at up to 5 fps, and sends no per-frame main-thread work while the recipe is neutral. Saved media continues to render at full quality after capture. This is a stability safeguard for iPhone hardware, not a reduction in recorded quality. The comparison source, [CameraKit iOS](https://github.com/CameraKit/camerakit-ios), is a camera-session wrapper with separate preview/session responsibilities, automatic preview scaling/orientation, and photo/video session APIs; it does not provide a proprietary image-filtering algorithm to copy.

ISO follows the requested discrete sequence: 50, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400. Shutter follows the requested sequence from 1/3 through 1/2000. Both lists are filtered to the active camera format before selection—Apple's format limits remain authoritative. Photo mode has one circular mm control that cycles lenses on tap, and Settings includes a persisted zoom cap; camcorder drag uses a smoothstep S-curve response.

## Capture lifecycle and formats — October 20

InCam now starts motion sensing only while its camera screen is active, and stops device motion, microphone metering, the capture session, and any active recording when the app becomes inactive, backgrounds, or the camera screen disappears. This is deliberately a battery safeguard: no camera or microphone work is retained while InCam is not being used. It follows [Apple's AVCam camera-session sample](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) and `AVCaptureSession`'s documented start/stop data flow. Physical-device testing is still required to measure battery use; a live camera preview necessarily uses power while it is open.

Below Audio, compact circular controls now cycle only the device-supported 720p/1080p/4K session presets, 24/25/30 fps, and H.264/HEVC codecs. HDR is enabled only when the active format reports it is controllable, and RAW is shown as an availability status rather than a false capture setting until a separate DNG-saving photo pipeline is completed. The shutter preset list restores 1/30. Codec availability comes from `AVCaptureMovieFileOutput.availableVideoCodecTypes`; resolution/preset, HDR, and RAW availability can change with the active lens/format. This is supported by [Apple's AVCaptureMovieFileOutput API](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput), [HDR capture-device API](https://developer.apple.com/documentation/avfoundation/avcapturedevice/isvideohdrenabled), and [RAW photo availability API](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/availablerawphotopixelformattypes).

## Preview responsiveness and private gallery — October 20

Tint, Saturation, and Contrast now use a fast low-resolution global Core Image preview path at up to 10 fps. Selective Camera Colors/HSL remains separately throttled because it requires a color-cube render; only one frame may wait for display in either case. Final saved photos and movies still use the full-quality recipe render. Physical-device profiling remains necessary, especially on older phones.

## Color-range fine scrubbing — October 21

The Camera Colors strip exposes all eight stored HSL ranges (red, orange, yellow, green, aqua, blue, purple, and magenta). A drag that starts on the strip remains a color-range drag after the finger moves vertically away from it. Increasing that vertical distance raises the horizontal travel required for each range, providing a close/fast and distant/precise scrub without making the nearby HUE/SAT/LUM ruler compete for the gesture. This selects recipe ranges only. It does **not** claim to provide a live pixel mask or a live zebra overlay: those require a separately tested video-analysis output and are not represented by a fake full-screen tint.

The October 21 live Color Mix pass uses an `AVCaptureVideoDataOutput` only when at least one selective HSL value differs from neutral. Its newest IOSurface-backed camera frame is rendered directly by Core Image into an `MTKView` drawable through Metal—there is no `UIImage` conversion or artificial eight-frame-per-second cap. The MTK view presents at 30 fps and retains only the newest captured frame, so late frames are dropped rather than queued. The output and Metal display pause again at neutral values or when InCam is inactive. The native preview remains in place for neutral shooting and for global controls. This compiles against the Simulator SDK; color accuracy, frame alignment, thermals, and battery behavior still require physical-iPhone testing.

Manual shutter speed is persisted separately from the live automatic-exposure reading. In a dark scene the camera may currently meter at a long value such as 1/3; opening the manual shutter ruler instead starts at the last deliberate speed. That value is matched to the closest speed available on the active lens/format, since the format’s exposure limits remain authoritative.

CameraKit's public source was reviewed for this issue. Its preview is a plain `AVCaptureVideoPreviewLayer` with no live CI filtering, so it cannot supply the required color adjustments directly. InCam now follows the relevant performance principle—keep the native preview underneath—but presents the adjustment overlay through a Metal-backed Core Image view instead of converting every frame into `CGImage` and `UIImage`. Basic global Tint/Saturation/Contrast is capped at 20 fps; selective HSL is capped at 10 fps because it needs a color cube. The filtered overlay renders at 70% display resolution only; saved outputs retain full resolution. Source: [CameraKit's preview implementation](https://github.com/CameraKit/camerakit-ios/blob/master/CameraKit/CameraKit/CKFPreviewView.swift).

The Camera Colors range strip is widened to 92 points. RESET and SAVE use larger 32-point targets with a visual/touch gap below the HUE/SAT/LUM controls. RESET clears the whole unsaved color draft—including basic Tint/Saturation/Contrast and all HSL ranges—while leaving saved Custom Color slots intact. SAVE stores the complete current draft in the active/first empty quick slot.

The camera control surfaces now use system ultra-thin material blur with a restrained light-to-charcoal gradient, replacing flat opaque charcoal. The right control surface remains visually distinct from the live camera viewport as required, but its material responds to available backdrop color. Audio removes the `A` label and displays two actual capture-channel tracks horizontally. Resolution, frame-rate, codec, RAW-capability, and HDR controls use the same compact rounded-rectangle geometry as Ratio, Grid, and Audio.

InCam's Gallery no longer requests Photos read/write access or fetches `PHAsset` objects. Each InCam photo/video is copied into the app's private Application Support storage and the gallery reads only that list. InCam still requests Apple's add-only Photos permission when it offers to save a second copy to the system Photos library. The copied gallery content is private to InCam and is removed if the app is deleted; it is not a replacement for an exported Photos copy.

## Fuji-inspired recipe controls — October 20

The two supplied Fuji recipe screenshots are preserved as visual references for the recipe vocabulary and ordering: Film Simulation, Grain, Colour Chrome, White Balance with Red/Blue shift, Dynamic Range, Highlight/Shadow Tone, Colour, Sharpness, Noise Reduction, Clarity, Exposure Compensation, and ISO. The supplied originals are `Screenshot 2026-10-20 at 8.36.57 PM.heic` and `Screenshot 2026-10-20 at 8.36.31 PM.heic` from the user’s Messages attachments. They are references, not instructions that override InCam’s established landscape layout.

The dock now treats **Clarity**, Saturation, Contrast, and Camera Colors as the recipe-facing controls; Tint is deliberately a White Balance control using the device’s native `AVCaptureDevice` white-balance API on a visible -7…+7 scale. This removes the previous duplicate software tint transform that could make the image unexpectedly green/magenta. Clarity has a conservative Core Image preview treatment: a small luminance-detail adjustment for positive values and a mild soften for negative values. All recipe values remain bounded so a single drag cannot cause the extreme black, white, or neon clipping reported in testing.

The capture stack defaults to 4K/30 when the active device supports it, otherwise it falls back to a supported preset. HDR has been replaced by an in-app **LOG** workflow toggle. LOG disables the global Saturation and Contrast controls rather than silently combining them with a log-like workflow. It does **not** claim to enable Apple Log, ProRes, or a hardware log encoding profile; those require format- and device-specific capture configuration beyond this current `AVCaptureMovieFileOutput` pipeline.

Recipe workflow inspiration was reviewed from [FujiStyle’s applying-recipes guide](https://www.fujistyleapp.com/blog/fujistyle-app-guide-to-ios-connection-and-applying-recipes/), [Fujifilm’s guide to building a film-simulation recipe](https://www.fujifilm-x.com/en-gb/learning-centre/make-your-own-film-simulation-recipe/), and [Tom England’s settings guide](https://www.tom-england.com/blog/fujifilm-recipes-understanding-the-settings-and-perfecting-your-own). These sources inform terminology and the relationship between white balance, color, and recipe slots—not InCam’s exact layout or capture claims.

The Camera Colors renderer no longer applies recipe pre-tint. Existing saved drafts migrate that old software value to zero; White Balance’s real device Tint is the only Tint path. The right-side AE ruler is separated from the exposure target and has a taller 0.1 EV drag range, while its +/- controls retain 0.3 EV steps. This needs physical-iPhone touch testing because the Simulator does not provide a camera exposure device.

## A13 preview stability correction — October 20

An iPhone 11 / A13 crash reported as `AGXA13FamilyFunctionHandle resourceIndex` was traced to the optional Metal-backed Core Image live-preview overlay. That overlay has been removed. InCam now always uses the stable native `AVCaptureVideoPreviewLayer` for the live screen, so recipe operations cannot black out the preview. White Balance Tint remains a real `AVCaptureDevice` adjustment and is visible on the same right-side status rail as WB, shutter, and ISO. Recipe rendering remains available to the existing capture/export path, but it is no longer presented as a live filtered overlay until a device-safe renderer is verified on physical iPhones.

The bottom dock is now a 16-point rounded rectangle, not a capsule. It is 13% narrower than the current composition guide and recomputes its width/center as the selected aspect guide animates. This is a layout-only change: ratios remain composition guides and do not promise that the saved video is cropped.

## Final control and Gallery pass — October 20

AE now occupies the charcoal right-hand mousepad at the same center anchor used by the Clarity, Saturation, and Contrast rulers. Its target remains in the preview, while the adjustment itself stays out of the image. White Balance Tint’s visible -7…+7 numbers are unchanged, but each step now maps to a smaller native tint shift (12 rather than 14 native units), reducing the reported excessive green/magenta effect.

The dock is 20% narrower than the active composition guide, retaining its 44-point height and a 16-point rounded rectangle. Its category and value text is reduced by roughly 8%. The selected ratio recomputes the dock’s width and center every time.

Tapping Gallery while recording stops the recording instead of presenting Gallery before the file is finalized. A completed recording is copied into InCam’s private Gallery immediately; when a Camera Colors export completes, it replaces that same Gallery file with the processed result rather than creating another item. This preserves a prompt Gallery result while allowing completed recipe output to appear there. A single preview tap continues to map through `AVCaptureVideoPreviewLayer` and set the device focus point; the double-tap recognizer remains reserved for AE lock.

## Foreground-only capture lifecycle — October 21

The user reported that InCam remained a high battery user when it was not actively being used. The audit found three expensive resources that could remain active while a SwiftUI sheet covered the camera: the capture session, microphone meter/audio route, and device-motion updates. The unused secondary `AVCaptureVideoDataOutput` was also still receiving full camera frames after the Metal preview was removed.

InCam now uses only the native `AVCaptureVideoPreviewLayer`, photo output, and movie output. It releases the capture session, audio meter, active `AVAudioSession`, motion sensor, timer, and zoom ramp whenever the app is inactive/backgrounded **or** its Settings, Audio, or Gallery screen is open. Returning to the active, unobstructed camera screen starts only the required capture resources again. This intentionally prioritizes battery life over an instant live camera behind a settings screen.

The supplied [SamMobile background-app overview](https://www.sammobile.com/news/what-does-it-mean-when-apps-run-in-the-background/) was used as the problem framing: continuing CPU, memory, network, sensor, or audio work can consume battery even when a person is not interacting with an app. Its instructions are Android-oriented, so the implementation relies on iOS scene state and AVFoundation capture-session lifecycle behavior instead. Apple’s [AVCam camera sample](https://developer.apple.com/documentation/avfoundation/avcam-building-a-camera-app) and [app lifecycle documentation](https://developer.apple.com/documentation/uikit/managing-your-app-s-life-cycle) are the platform references. Physical-iPhone battery testing is still required to measure the result.

## Dock responsiveness and direct Camera Colors — October 21

The Camera dock is now 72% of the active composition-guide width, retaining the same height and rounded-rectangle form so it clears nearby controls. Basic recipe feedback uses lightweight SwiftUI compositing over the stable native camera preview: Saturation and Contrast respond immediately, while positive Clarity contributes a deliberately modest contrast/detail cue and negative Clarity softens the view. This avoids restoring the custom per-frame Metal renderer that crashed on A13 iPhones. Selective HSL/Camera Colors remains an exported-render feature until a device-safe selective live-render pipeline is verified.

AE lock now uses the same 112-point vertical ruler and central numeric presentation as the other right-side adjustment dials, with AE LOCK above and ±0.3 EV buttons around the ruler. The target remains in the viewfinder while its control lives on the right mousepad.

Camera Colors has a direct shooting path: the first tap enables the mode; subsequent taps rotate through only filled Custom Color quick slots. Empty slots are skipped. Holding Camera Colors opens detailed HSL editing, leaving normal capture interaction one-tap and predictable. This preserves the requested distinction between simple on-camera mode selection and deliberate recipe editing.

## Top-row audio and explicit Auto — October 21

The on-camera audio meter now shares the top row with the capture timer. It renders one empty/quiet meter when no active channel value is available and adds a second track only when AVFoundation reports a genuine second capture channel. The Audio settings screen exposes that same automatic one- or two-channel state; InCam does not invent a second signal.

Ratio and Grid now open a shared tap-choice panel, so a person can select a saved ratio or a grid type directly. These remain composition overlays and do not crop the captured recording. Video output is consolidated into one `4K 30 FPS` control that reveals the supported resolution, frame-rate, codec, RAW availability, and Log choices beside it.

The supplied [PRO EDU Auto Mode article](https://proedu.com/blogs/photography-fundamentals/decoding-auto-mode-in-cameras-when-to-use-it) informed the product behavior: Auto is an explicit mode, not a label. InCam’s Auto action asks the physical camera for continuous automatic exposure or white balance; a manual shutter/ISO/WB edit changes that setting to Manual. The page was unavailable to the source reader, so this records the user-supplied link without attributing any unverified wording to it.

## Custom Color slot cycling and Zebra limitation — October 21

Camera Colors now advances through all five named Custom Color slots in a fixed `1 → 2 → 3 → 4 → 5` loop. Filled slots load their saved recipe; an empty slot loads a neutral recipe ready for editing and saving. This ensures the right-hand title identifies the actual editing target rather than showing a generic Camera Colors label.

Selective HSL recipes are applied to the saved-video export via Core Image’s color-cube renderer. The stable live preview uses `AVCaptureVideoPreviewLayer` after the prior custom live rendering path caused black previews/crashes on A13 hardware. A true real-time, pixel-accurate Zebra mask for a selected HSL color needs a separately validated live pixel-analysis renderer; InCam does not currently show a fake Zebra that would claim to identify yellow/blue pixels without analyzing them.

## Startup defaults, Auto readouts, and Settings categories — October 21

New capture sessions request the active lens's supported **4K / 24 fps** profile. The manual shutter baseline is **1/60**, and the neutral white-balance reference displayed by InCam starts at **5700 K / tint 0**. Continuous Auto White Balance remains a device-owned operation; its rapidly changing sensor gains are intentionally not presented as precise Kelvin/tint measurements because those conversions can look falsely warm, cool, green, or magenta in the UI. Manual ISO choices and readouts use 100-ISO increments.

The Settings screen is divided into **Favorites**, **Video**, **Photo**, and **Audio**. Favorites is configurable and changes the same underlying settings as the dedicated categories; it is not a duplicate settings model. Video lists only resolution, frame rate, codec, Log, and HDR choices reported by the active camera. Physical-iPhone testing remains necessary because support differs by lens and format.

The composition grid mode and the Level guide are stored locally and restored when the camera view returns. They remain on-screen composition/monitoring tools; neither changes the recording crop.

## Stereo meter, Custom Colors, and manual focus — October 24

The top-left audio control now exposes actual capture channels as **L** and **R** tracks. A built-in iPhone microphone may report only a mono L track; InCam adds R only when AVFoundation exposes a genuine second audio channel. Tapping the meter opens a narrow in-camera column directly to its right, rather than covering Audio, Grid, or Format. That quick column only offers Mono/Stereo, Input, and Output. It displays the normal system route as muted **None**, and brightens an explicitly selected output. Capture-channel detail and gain remain available in Settings; this keeps the shooting surface small.

Camera Colors has seven migrated quick slots. A Camera Colors tap opens the right-side slot picker without changing the active look. Vertical scrubbing chooses an exact slot and loads its recipe. All visible recipe adjustments (Clarity, Saturation, Contrast, and HSL) now activate the direct Core Image/Metal preview path, and the same recipe is snapshotted when photo/video capture begins. Photos render before InCam saves them; movies are rendered after recording and replace the temporary private-gallery copy when export succeeds. Physical-device testing remains required for final timing, thermal behavior, and actual movie-export completion.

## Capture-stop and codec policy — October 25

The shutter ruler uses the supplied familiar stops from **30 seconds through 1/8000**, filtered by the active format's actual duration limits. The exact **1/120** value remains alongside 1/125 because it is the requested 60 fps, 180-degree-style reset. A new frame-rate choice is remembered and resets the *manual* shutter baseline to the matching value: 24 fps → 1/50, 30 fps → 1/60, and 60 fps → 1/120. Auto exposure is not overridden by that reset.

ISO now uses the supplied discrete list—100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, and 8000—without rounding 125/160/640 to a hundred. Values unavailable on the active lens remain hidden because Apple exposes min/max ISO per active capture format.

Video defaults to HEVC when the active output reports it, with H.264 as fallback. ProRes 422 LT, 422, and 422 HQ appear only if `AVCaptureMovieFileOutput.availableVideoCodecTypes` includes the matching codec for the current device, lens, and session. This follows Apple's [available codec types documentation](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput/availablevideocodectypes) and its [output-settings requirements](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput/setoutputsettings%28_%3Afor%3A%29): a selected codec must be in the output's supported list. A generic **RAW video** option is intentionally not displayed; a codec name being defined by AVFoundation does not establish that the active iPhone can record it through this session.

Double-tapping any shutter control now toggles its **Speed/Angle** presentation instead of resetting shutter duration. This is a presentation-only preference stored locally; it neither changes Auto/Manual exposure nor modifies the selected duration. The angle uses `duration × frame rate × 360`, capped at 360 degrees, matching the existing Speed/Angle model. Completed product changes are also tracked in `CHANGELOG.md` so the user-visible change history remains separate from source and limitation notes.

## Readout gesture boundaries, front mirroring, and CC tiles — October 25

The compact WB/Tint/Shutter/ISO rail now has an explicit preview-gesture exclusion zone. This ensures that one or two taps on a readout are handled by that readout’s SwiftUI control rather than passing through to the native preview’s focus or exposure recognizers. A focus target remains a short-lived visual confirmation only; clearing it never changes the active focus point or AF/MF state.

Front-facing preview, photo, and movie connections explicitly disable automatic mirroring and set `isVideoMirrored` from the selected camera direction after a camera switch. This follows Apple’s [camera-direction guidance](https://developer.apple.com/documentation/avkit/choosing-a-camera-by-the-direction-it-faces?language=objc) and avoids assuming that a live input swap will preserve a user-facing preview orientation.

The CC picker only loads a selected recipe into the on-demand preview/render path. Its other slot tiles are data only; they neither add a capture output nor process frames while unselected. This preserves the existing foreground-only and active-recipe-only optimization policy.

## Front-camera reflection, lens restoration, and shutter stops — October 25

Front preview reflection is now a screen-space transform across the y-axis after the interface orientation has settled. The photo and movie output connections are intentionally left unmirrored so the preview transform cannot be applied twice to saved captures. InCam remembers the selected rear device identifier before a front-camera switch; returning to rear uses that exact device when present, otherwise it deliberately falls back to the Wide camera instead of relying on AVFoundation discovery ordering.

Shutter controls use an explicit, documented list of user-requested values—including 1/50, 1/100, 1/400, and 1/620—rather than a generated stop sequence. The list is still filtered by the active device format’s safe manual-exposure duration range; a device can reject a duration it does not support, but InCam no longer accidentally removes it from the source sequence.

## Level indicator and shutter-display synchronization — October 25

The on-screen level is a stable roll-only monitoring indicator: short / long / short horizontal dashes, with the longer center dash glowing green inside a 0.7-degree roll tolerance. It intentionally does not rotate, slide, or derive a false moving “center” from pitch. The requested more detailed camera-style leveling reference can still inform a later, separate plane/tilt visualization.

Auto exposure can report arbitrary durations between familiar camera stops. InCam now maps both the compact shutter readout and the open ruler to the same nearest preset within the active device format's safe exposure range. This keeps the interface internally consistent without falsely claiming that AVFoundation metered the exact rounded preset.

When the shooter changes frame rate, InCam intentionally exits shutter Auto and applies a 180-degree-style, 2×-FPS manual shutter baseline. The supported defaults are 24/25 fps → 1/50, 30 → 1/60, 60 → 1/120, and 120 → 1/240. The active format still provides the final safety clamp before the duration is applied.

The level guide uses `CMMotionManager` device-motion attitude. Because attitude is expressed in the phone's native portrait axes, InCam remaps roll and pitch into the active interface orientation before drawing a screen-horizontal camera-level guide. It is an aid rather than a calibrated surveying instrument; the green state requires both roll and pitch to be inside small tolerances.

To keep the foreground UI responsive, Level starts `CMMotionManager` only while the user has enabled Level, and stops it immediately when Level is disabled or the camera view goes away. Audio meter state is sampled at five hertz, which is sufficient for compact visual metering without forcing high-frequency SwiftUI layout updates. Preview orientation work is also guarded against identical state.

When Auto is enabled, InCam observes the active capture device's exposure duration, ISO, and white-balance gains so its readouts follow the camera’s current metering as lighting changes. Manual shutter/ISO/WB edits turn off the matching Auto mode before setting hardware values, preventing an observer from overwriting a deliberate choice. This behavior relies on the active device’s reported values; the simulator cannot validate live camera metering.

Audio now always renders visible **L** and **R** meter tracks. A physically unavailable channel remains an empty track rather than mirroring the other channel or creating synthetic levels. InCam requests Mono or Stereo through the active `AVAudioSession`, but an iPhone microphone may remain mono; the current route and actual `AVCaptureConnection.audioChannels` determine what is recorded. iOS allows a preferred input and an optional speaker override but does not let apps arbitrarily select every output device, so the Output choice is limited to System routing or the phone speaker.

Private captures now use an app-controlled folder and sequential file name. The current `AVCaptureMovieFileOutput` pipeline produces QuickTime `.mov` movies; a valid `.mp4` requires a separate compatible export pass. InCam therefore does not relabel a MOV payload as MP4, since that would create a misleading extension. The folder/date naming affects InCam's private gallery only and still does not grant broad Photos-library read access.

Manual focus now leaves the Record control visible. In MF, tapping empty space on the right mousepad dismisses its ruler; a vertical swipe in that mousepad reopens the ruler and updates device focus without stopping an active recording.

## Missing attachments

The following referenced screenshots are listed here, but their temporary source files were already unavailable when supplied. No copies have been saved and no content is inferred from them. Reattach them to preserve and inspect them.

- `simulator_screenshot_AFA9FE32-2478-4B94-80CC-8E7B223981B2.png`
- `simulator_screenshot_B4AFBD55-6519-4E19-AD71-193C092ABE39.png`
- `simulator_screenshot_1B65CFC7-7D9F-4B5D-AA28-802F01903B0E.png`
