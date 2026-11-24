import Foundation

// FILE GUIDE: Temporary product switches for features intentionally hidden
// from the shipping UI. The source remains compiled and recoverable; changing
// a value here is explicit and does not delete a feature's implementation.
enum AppFeatureAvailability {
    /// PAUSED FEATURE: Gallery is compiled so its source stays valid, but its
    /// entry points are hidden while its information architecture is redesigned.
    static let gallery = false

    /// PAUSED FEATURE: Camera Colors editor is compiled but inaccessible while
    /// its UI/UX and rendering workflow are redesigned. Recipe data is preserved.
    static let cameraColorsEditor = false

    /// PAUSED FEATURE: The quick Clarity, Saturation, and Contrast controls are
    /// hidden from the capture dock. Their recipe values and adjustment code remain
    /// intact, so this does not discard a user's existing color settings.
    static let basicColorControls = false

    /// PAUSED FEATURE: This gates the legacy on-camera color dock and its live
    /// preview path. The independent reference-image Color workspace has its
    /// own launcher and continues to save recipe data without enabling this
    /// renderer or altering capture output.
    static let cameraColors = false

    /// ACTIVE: The format tray lists 4K only where the current physical lens
    /// and frame rate can support it. The app still starts at the saved 1080p
    /// setting, so enabling the choice does not make launch heavier.
    static let fourKCapture = true

    /// PAUSED FEATURE: Settings entry points and the settings drawer are unavailable
    /// while the settings experience is reorganized. Preferences and source code stay
    /// compiled and recoverable; only presentation is disabled.
    static let settings = false
}
