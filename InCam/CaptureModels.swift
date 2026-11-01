import CoreGraphics
import Combine
import Foundation

enum CaptureMode: String, CaseIterable, Codable {
    case photo
    case video

    var letter: String { self == .photo ? "P" : "V" }
}

/// Capture choices exposed in the left-side tool stack. They are deliberately
/// separate from composition ratios: these settings change the camera output,
/// while ratios only change the on-screen framing guide.
enum VideoResolution: String, CaseIterable, Codable, Identifiable {
    case p720 = "720p"
    case p1080 = "1080p"
    case p4K = "4K"

    var id: String { rawValue }
    var compactLabel: String {
        switch self {
        case .p720: return "720"
        case .p1080: return "1080"
        case .p4K: return "4K"
        }
    }
}

/// Movie codecs are listed only when AVFoundation reports support for the
/// currently selected camera format and session preset.
enum VideoCodec: String, CaseIterable, Codable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"
    case proRes422LT = "ProRes 422 LT"
    case proRes422 = "ProRes 422"
    case proRes422HQ = "ProRes 422 HQ"

    var id: String { rawValue }
    var compactLabel: String {
        switch self {
        case .h264: return "H264"
        case .hevc: return "HEVC"
        case .proRes422LT: return "PR LT"
        case .proRes422: return "PR 422"
        case .proRes422HQ: return "PR HQ"
        }
    }
}

/// Stabilization is a property of the active video connection, not a promise
/// that every lens, resolution, or frame rate can support every mode.
enum VideoStabilization: String, CaseIterable, Codable, Identifiable {
    case off = "Off"
    case auto = "Auto"
    case standard = "Standard"
    case cinematic = "Cinematic"

    var id: String { rawValue }
}

/// Still-photo speed modes deliberately exclude deferred photo delivery.
/// Apple completes deferred proxies through the Photos library, while InCam's
/// gallery stores only private, app-owned media.
enum PhotoSpeedMode: String, CaseIterable, Codable, Identifiable {
    case standard = "Standard"
    case responsive = "Responsive"

    var id: String { rawValue }
}

enum CameraHealth: Equatable {
    case starting
    case ready
    case recovering(String)
    case pressure(String)
    case unavailable(String)

    var message: String? {
        switch self {
        case .ready: return nil
        case .starting: return "Starting camera…"
        case .recovering(let message), .pressure(let message), .unavailable(let message): return message
        }
    }
}

/// The preferred channel layout requested from the selected microphone. The
/// active route remains authoritative—some built-in iPhone microphones are
/// physically mono and cannot provide a genuine right channel.
enum AudioChannelMode: String, CaseIterable, Codable, Identifiable {
    case mono = "Mono"
    case stereo = "Stereo"

    var id: String { rawValue }
    var requestedChannelCount: Int { self == .mono ? 1 : 2 }
}

enum AudioOutputMode: String, CaseIterable, Codable, Identifiable {
    case system = "System"
    case speaker = "Speaker"

    var id: String { rawValue }
}

enum RecordingNamingMode: String, CaseIterable, Codable, Identifiable {
    case sequence = "Folder sequence"
    case date = "Date sequence"

    var id: String { rawValue }
}

/// Shared exposure vocabulary for every InCam shutter readout and reset path.
/// Keeping it here prevents the camera screen and the compact dock from
/// silently drifting to different "default" shutter speeds.
enum CameraExposureDefaults {
    static let defaultShutterSeconds = 1.0 / 50.0
    static let retiredShutterSeconds = 1.0 / 14.0

    /// The requested camera shutter-speed stops. Values at or slower than one
    /// second are deliberately represented as whole seconds. These are
    /// explicit values—not generated thirds—so 1/50, 1/100, 1/400, and the
    /// requested 1/620 never disappear when the UI sequence is updated.
    static let shutterSeconds: [Double] = [
        30, 15, 8, 4, 2, 1,
        1.0 / 2, 1.0 / 3, 1.0 / 4, 1.0 / 5, 1.0 / 6, 1.0 / 8,
        1.0 / 10, 1.0 / 13, 1.0 / 15, 1.0 / 16, 1.0 / 20,
        1.0 / 24, 1.0 / 25, 1.0 / 30, 1.0 / 40, 1.0 / 50,
        1.0 / 60, 1.0 / 80, 1.0 / 100, 1.0 / 120, 1.0 / 125,
        1.0 / 160, 1.0 / 200, 1.0 / 240, 1.0 / 250, 1.0 / 320, 1.0 / 400,
        1.0 / 500, 1.0 / 620, 1.0 / 640, 1.0 / 800, 1.0 / 1_000,
        1.0 / 1_250, 1.0 / 1_600, 1.0 / 2_000, 1.0 / 4_000,
        1.0 / 8_000
    ]

    static let shutterAngleDegrees: [Double] = [
        11.25, 22.5, 45, 72, 90, 120, 135, 144, 172.8, 180,
        225, 240, 270, 288, 360
    ]

    /// One canonical display candidate is shared by the compact readout and
    /// its ruler. Auto may meter a non-standard duration such as 1/47, but
    /// both controls then show the same nearest selectable shutter value.
    static func displayDuration(for seconds: Double, frameRate: Int,
                                angleMode: Bool, supportedRange: ClosedRange<Double>) -> Double {
        let fps = Double(max(1, frameRate))
        let candidates = angleMode
            ? shutterAngleDegrees.map { $0 / (fps * 360) }
            : shutterSeconds
        let available = candidates.filter {
            $0 >= supportedRange.lowerBound - 0.000_000_1 &&
            $0 <= supportedRange.upperBound + 0.000_000_1
        }
        let choices = available.isEmpty ? [supportedRange.lowerBound] : available
        return choices.min(by: { abs($0 - seconds) < abs($1 - seconds) }) ?? choices[0]
    }

    static func speedLabel(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.1f s", seconds)
            : "1/\(Int(min(100_000, (1 / seconds).rounded())))"
    }

    /// A 180°-style reset is twice the active frame rate. 24 fps maps to the
    /// requested 1/50 display stop, while 60 fps keeps its exact 1/120 stop.
    static func recommendedShutterSeconds(for frameRate: Int) -> Double {
        switch frameRate {
        case 24, 25: return 1.0 / 50.0
        case 30: return 1.0 / 60.0
        case 60: return 1.0 / 120.0
        default:
            let target = 1.0 / Double(max(1, frameRate * 2))
            return shutterSeconds.min(by: { abs($0 - target) < abs($1 - target) }) ?? defaultShutterSeconds
        }
    }
}

/// An item stored in InCam's private on-device gallery. The app saves its own
/// captures here so the gallery never needs permission to browse all Photos.
struct InCamSavedMedia: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case photo, video }

    let id: UUID
    let filename: String
    let kind: Kind
    let createdAt: Date
}

enum CompositionRatio: String, CaseIterable, Codable, Identifiable, Hashable {
    case square = "1:1"
    case fourThree = "4:3"
    case threeTwo = "3:2"
    case fiveFour = "5:4"
    case sevenFive = "7:5"
    case sixteenNine = "16:9"
    case verticalVideo = "9:16"
    case portraitPhoto = "4:5"
    case cinemaFlat = "1.85:1"
    case cinemaScope = "2.39:1"

    static let catalog: [Self] = [.sixteenNine, .fourThree, .threeTwo, .square, .portraitPhoto, .verticalVideo, .cinemaFlat, .cinemaScope]

    var id: String { rawValue }

    func label(isPortrait: Bool) -> String {
        guard isPortrait else { return rawValue }
        switch self {
        case .fourThree: return "3:4"
        case .threeTwo: return "2:3"
        case .fiveFour: return "4:5"
        case .sevenFive: return "5:7"
        case .sixteenNine: return "9:16"
        default: return rawValue
        }
    }

    var value: CGFloat {
        switch self {
        case .square: return 1
        case .fourThree: return 4 / 3
        case .threeTwo: return 3 / 2
        case .fiveFour: return 5 / 4
        case .sevenFive: return 7 / 5
        case .sixteenNine: return 16 / 9
        case .verticalVideo: return 9 / 16
        case .portraitPhoto: return 4 / 5
        case .cinemaFlat: return 1.85
        case .cinemaScope: return 2.39
        }
    }
}

enum GridMode: String, CaseIterable, Codable, Hashable {
    case off
    case thirds
    case golden
    case spiral
    case diagonals
    static let choices: [GridMode] = [.off, .thirds, .golden, .diagonals]

    var shortLabel: String {
        switch self {
        case .off: return "GRID"
        case .thirds: return "3×3"
        case .golden: return "φ"
        case .spiral: return "SPIRAL"
        case .diagonals: return "DIAG"
        }
    }
}

enum DockItem: String, CaseIterable, Identifiable {
    case whiteBalance = "WB"
    case rateOrFormat = "FPS"
    case shutter = "SHUTTER"
    case iso = "ISO"
    case cameraColor = "CC"
    case zoom = "ZOOM"

    var id: String { rawValue }
}

enum CameraControlLayout: String, CaseIterable, Identifiable {
    case floating = "Floating box"
    case dock = "Bottom dock"
    var id: String { rawValue }
}

enum CameraControlPage: Int, CaseIterable, Identifiable {
    case whiteBalance, tint, shutter, iso, rateOrFormat, cameraColor, zoom
    var id: Int { rawValue }

    init(_ item: DockItem) {
        switch item {
        case .whiteBalance: self = .whiteBalance
        case .shutter: self = .shutter
        case .iso: self = .iso
        case .rateOrFormat: self = .rateOrFormat
        case .cameraColor: self = .cameraColor
        case .zoom: self = .zoom
        }
    }

    var dockItem: DockItem {
        switch self {
        case .whiteBalance, .tint: return .whiteBalance
        case .shutter: return .shutter
        case .iso: return .iso
        case .rateOrFormat: return .rateOrFormat
        case .cameraColor: return .cameraColor
        case .zoom: return .zoom
        }
    }

    func title(for mode: CaptureMode) -> String {
        switch self {
        case .whiteBalance: return "White Balance"
        case .tint: return "Tint"
        case .shutter: return "Shutter"
        case .iso: return "ISO"
        case .rateOrFormat: return mode == .video ? "FPS" : "Format"
        case .cameraColor: return "Camera Color"
        case .zoom: return "Zoom"
        }
    }

    func adjacent(forward: Bool) -> CameraControlPage {
        Self.allCases[min(Self.allCases.count - 1, max(0, rawValue + (forward ? 1 : -1)))]
    }
}

/// Screen visibility is opt-in for custom buttons; hiding never deletes assignments.
@MainActor
final class CameraScreenPreferences: ObservableObject {
    @Published var showCustom1: Bool { didSet { defaults.set(showCustom1, forKey: "incam.screen.c1") } }
    @Published var showCustom2: Bool { didSet { defaults.set(showCustom2, forKey: "incam.screen.c2") } }
    @Published var showMainControls: Bool { didSet { defaults.set(showMainControls, forKey: "incam.screen.controls") } }
    @Published var showQuickRow: Bool { didSet { defaults.set(showQuickRow, forKey: "incam.screen.quickRow") } }
    /// Guides stay non-destructive by default. This opt-in asks the capture
    /// pipeline to center-crop the private and Photos copies to the selected
    /// guide after capture.
    @Published var saveFramedOutput: Bool { didSet { defaults.set(saveFramedOutput, forKey: "incam.screen.save-framed-output") } }
    var framingGuide: Bool { !ratioShortcuts.isEmpty }
    @Published var selectedRatio: CompositionRatio { didSet { defaults.set(selectedRatio.rawValue, forKey: "incam.screen.ratio") } }
    @Published var ratioShortcuts: [CompositionRatio] {
        didSet { defaults.set(ratioShortcuts.map(\.rawValue), forKey: "incam.screen.ratios") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showCustom1 = defaults.bool(forKey: "incam.screen.c1")
        showCustom2 = defaults.bool(forKey: "incam.screen.c2")
        showMainControls = defaults.object(forKey: "incam.screen.controls") as? Bool ?? true
        showQuickRow = defaults.object(forKey: "incam.screen.quickRow") as? Bool ?? true
        saveFramedOutput = defaults.bool(forKey: "incam.screen.save-framed-output")
        selectedRatio = CompositionRatio(rawValue: defaults.string(forKey: "incam.screen.ratio") ?? "") ?? .fourThree
        let saved = (defaults.stringArray(forKey: "incam.screen.ratios") ?? []).compactMap(CompositionRatio.init(rawValue:))
        ratioShortcuts = defaults.object(forKey: "incam.screen.ratios") == nil ? [.fourThree, .sixteenNine, .square] : saved.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if !ratioShortcuts.contains(selectedRatio), let first = ratioShortcuts.first { selectedRatio = first }
    }

    func toggleRatio(_ ratio: CompositionRatio) {
        if ratioShortcuts.contains(ratio) { ratioShortcuts.removeAll { $0 == ratio } }
        else { ratioShortcuts.append(ratio) }
        if !ratioShortcuts.contains(selectedRatio), let first = ratioShortcuts.first { selectedRatio = first }
    }

    func setRatioShortcut(_ ratio: CompositionRatio, at index: Int) {
        guard ratioShortcuts.indices.contains(index) else { return }
        var ratios = ratioShortcuts
        if let existing = ratios.firstIndex(of: ratio) { ratios.swapAt(existing, index) }
        else { ratios[index] = ratio }
        ratioShortcuts = ratios
        if !ratios.contains(selectedRatio) { selectedRatio = ratios[0] }
    }
}

struct CameraLensOption: Identifiable, Equatable {
    let id: String
    let name: String
    /// Horizontal 35 mm-equivalent estimate for this lens's active video format.
    /// Nil means the camera did not report a usable field of view.
    var equivalentMillimeters: Int? = nil
    var isPreview = false

    var millimeterLabel: String {
        guard let equivalentMillimeters else { return name }
        return "\(isPreview ? "" : "≈")\(equivalentMillimeters) mm"
    }
}

enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case unassigned = "Unassigned"
    case aspectRatio = "Aspect"
    case whiteBalance = "WB"
    case shutter = "Shutter"
    case iso = "ISO"
    case focus = "Focus"
    case exposureCompensation = "EV"
    case cameraColor = "CC"
    case grid = "Grid"
    case level = "Horizon Level"

    var id: String { rawValue }
}

struct CameraCapabilities: Equatable {
    var minISO: Float = 25
    var maxISO: Float = 2000
    var minExposureSeconds = 1.0 / 10_000
    var maxExposureSeconds = 1.0
    var minZoom: CGFloat = 1
    var maxZoom: CGFloat = 1
    var frameRates: [Int] = [24, 30, 60]
    var photoFormats: [String] = ["HEIF", "JPEG"]
    var resolutions: [String] = ["12 MP"]

    /// The active camera format is the source of truth. The dial includes
    /// values below ISO 100 only when the selected lens/format supports them.
    var manualISORange: ClosedRange<Double> {
        Double(minISO)...Double(maxISO)
    }

    func manualISO(_ requested: Float) -> Float {
        let range = manualISORange
        return Float(min(range.upperBound, max(range.lowerBound, Double(requested))))
    }

    /// User-selected manual dial limit; hardware limits still take priority.
    var manualExposureRange: ClosedRange<Double> {
        let fastest = min(maxExposureSeconds, max(minExposureSeconds, 1.0 / 8_000))
        return fastest...maxExposureSeconds
    }

    func manualExposure(_ requested: Double) -> Double {
        let range = manualExposureRange
        return min(range.upperBound, max(range.lowerBound, requested))
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    @Published var c1: [ShortcutAction] { didSet { persist() } }
    @Published var c2: [ShortcutAction] { didSet { persist() } }
    @Published var c1Name: String { didSet { persistNames() } }
    @Published var c2Name: String { didSet { persistNames() } }

    private let c1Key = "incam.shortcuts.v2.c1"
    private let c2Key = "incam.shortcuts.v2.c2"
    private let c1NameKey = "incam.shortcuts.v2.c1Name"
    private let c2NameKey = "incam.shortcuts.v2.c2Name"

    init() {
        c1 = Self.read(c1Key) ?? Array(repeating: .unassigned, count: 4)
        c2 = Self.read(c2Key) ?? Array(repeating: .unassigned, count: 4)
        c1Name = UserDefaults.standard.string(forKey: c1NameKey) ?? "C1"
        c2Name = UserDefaults.standard.string(forKey: c2NameKey) ?? "C2"
    }

    private static func read(_ key: String) -> [ShortcutAction]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let actions = try? JSONDecoder().decode([ShortcutAction].self, from: data),
              actions.count == 4 else { return nil }
        return actions
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(c1) { UserDefaults.standard.set(data, forKey: c1Key) }
        if let data = try? JSONEncoder().encode(c2) { UserDefaults.standard.set(data, forKey: c2Key) }
    }

    private func persistNames() {
        UserDefaults.standard.set(c1Name, forKey: c1NameKey)
        UserDefaults.standard.set(c2Name, forKey: c2NameKey)
    }
}
