import CoreImage
import Foundation
import SwiftUI

struct HSLAdjustment: Codable, Equatable {
    var hue: Double = 0
    var saturation: Double = 0
    var luminance: Double = 0
    var range: Double = 0.5
    var falloff: Double = 0.5
}

enum HSLBand: String, CaseIterable, Codable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .aqua: return .cyan
        case .blue: return .blue
        case .purple: return .purple
        case .magenta: return Color(red: 0.95, green: 0.1, blue: 0.65)
        }
    }
}

struct CameraColorRecipe: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var clarity: Double = 0
    var sharpening: Double = 0
    var threshold: Double = 0
    var preTint: Double = 0
    var saturation: Double = 0
    var contrast: Double = 0
    var hsl: [HSLBand: HSLAdjustment] = [:]
    var blackAndWhite = false
    var grainAmount: Double = 0
    var grainSize: Double = 0.4
    var grainRoughness: Double = 0.4
    var grainSoftness: Double = 0.4
    var grainPattern = "Fine"

    func hasSameAdjustments(as other: CameraColorRecipe) -> Bool {
        var lhs = self
        var rhs = other
        lhs.id = rhs.id
        lhs.name = rhs.name
        for band in HSLBand.allCases {
            lhs.hsl[band] = lhs.hsl[band] ?? HSLAdjustment()
            rhs.hsl[band] = rhs.hsl[band] ?? HSLAdjustment()
        }
        return lhs == rhs
    }

    /// Names and slot identifiers do not affect pixels. This check prevents a
    /// neutral recipe from replacing the efficient native camera preview.
    var hasVisibleAdjustments: Bool {
        if blackAndWhite || abs(clarity) > 0.0001 || abs(sharpening) > 0.0001 ||
            abs(preTint) > 0.0001 || abs(saturation) > 0.0001 || abs(contrast) > 0.0001 ||
            grainAmount > 0.0001 { return true }
        return hsl.values.contains { adjustment in
            abs(adjustment.hue) > 0.0001 || abs(adjustment.saturation) > 0.0001 || abs(adjustment.luminance) > 0.0001
        }
    }

    /// Selective HSL needs a color-cube render; the three basic controls do
    /// not. The preview uses this distinction to keep normal Tint/Saturation/
    /// Contrast adjustments responsive.
    var hasSelectiveColorAdjustments: Bool {
        hsl.values.contains { adjustment in
            abs(adjustment.hue) > 0.0001 || abs(adjustment.saturation) > 0.0001 || abs(adjustment.luminance) > 0.0001
        }
    }

    static let starters: [CameraColorRecipe] = [
        .init(name: "Neutral"),
        .init(name: "Cinema", saturation: -0.08, contrast: 0.14, grainAmount: 0.08),
        .init(name: "Warm", preTint: 0.1, saturation: 0.08),
        .init(name: "Chrome", sharpening: 0.16, saturation: 0.12, contrast: 0.22),
        .init(name: "Soft", clarity: -0.18, contrast: -0.08, grainSoftness: 0.75),
        .init(name: "Amber", preTint: 0.2, saturation: -0.04, grainAmount: 0.12),
        .init(name: "Mono", contrast: 0.18, blackAndWhite: true, grainAmount: 0.16),
    ]
}

@MainActor
final class CameraColorStore: ObservableObject {
    @Published private(set) var quickSlots: [CameraColorRecipe?]
    @Published private(set) var slots: [CameraColorRecipe]
    @Published var selectedSlot: Int?

    private let defaultsKey = "incam.camera-color-recipes.v1"
    private let quickSlotsKey = "incam.custom-colors.seven.v2"
    private let legacyQuickSlotsKey = "incam.custom-colors.five.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Seven quick slots supersede the earlier five-slot design. Existing
        // saved looks migrate in order, then gain two genuinely empty slots.
        let quickData = defaults.data(forKey: quickSlotsKey)
            ?? defaults.data(forKey: legacyQuickSlotsKey)
            ?? Data()
        let savedQuick = (try? JSONDecoder().decode([CameraColorRecipe?].self, from: quickData)) ?? []
        quickSlots = Array((savedQuick + Array(repeating: nil, count: 7)).prefix(7))
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([CameraColorRecipe].self, from: data),
           !decoded.isEmpty {
            slots = decoded
            if defaults.data(forKey: "incam.recipes.backup.before-ten-slots") == nil {
                defaults.set(data, forKey: "incam.recipes.backup.before-ten-slots")
            }
            for index in slots.indices where index < CameraColorRecipe.starters.count {
                let starter = CameraColorRecipe.starters[index]
                if slots[index].name == starter.name && slots[index].hasSameAdjustments(as: starter) {
                    slots[index].name = "Custom Color #\(index + 1)"
                }
            }
        } else {
            slots = []
        }
        while slots.count < 10 {
            slots.append(CameraColorRecipe(name: "Custom Color #\(slots.count + 1)"))
        }
        persist()
    }

    func save(_ recipe: CameraColorRecipe, to index: Int) {
        guard slots.indices.contains(index) else { return }
        var saved = recipe
        saved.id = slots[index].id
        slots[index] = saved
        selectedSlot = index
        persist()
    }

    func saveQuick(_ recipe: CameraColorRecipe, to index: Int) {
        guard quickSlots.indices.contains(index) else { return }
        quickSlots[index] = recipe
        if let data = try? JSONEncoder().encode(quickSlots) {
            defaults.set(data, forKey: quickSlotsKey)
        }
    }

    @discardableResult
    func addCustomColor() -> Int {
        slots.append(CameraColorRecipe(name: "Custom Color #\(slots.count + 1)"))
        persist()
        return slots.count - 1
    }

    func rename(at index: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard slots.indices.contains(index), !trimmed.isEmpty else { return }
        slots[index].name = trimmed
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(slots) { defaults.set(data, forKey: defaultsKey) }
    }

    var selectedRecipe: CameraColorRecipe? {
        guard let selectedSlot, slots.indices.contains(selectedSlot) else { return nil }
        return slots[selectedSlot]
    }
}

enum RecipeRenderer {
    static let context = CIContext(options: [.cacheIntermediates: true])
    private static let cubeLock = NSLock()
    private static var cubeCache: [Data: Data] = [:]

    static func render(_ image: CIImage, recipe: CameraColorRecipe) -> CIImage {
        var output = image
        // White-balance Tint belongs to AVCaptureDevice, not the recipe
        // renderer. Keeping it out of this path avoids a second, conflicting
        // green/magenta transform and keeps live preview responsive.
        output = output.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1 + recipe.contrast,
            kCIInputSaturationKey: recipe.blackAndWhite ? 0 : 1 + recipe.saturation,
        ])
        // Fuji-style clarity is deliberately bounded in ColorDockControls.
        // Positive values add restrained luminance detail; negative values
        // gently soften without creating the old extreme color shifts.
        if recipe.clarity > 0.0001 {
            output = output.applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 1.25,
                kCIInputIntensityKey: recipe.clarity * 0.65,
            ])
        } else if recipe.clarity < -0.0001 {
            let softened = output.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: abs(recipe.clarity) * 1.5])
            output = softened.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: output,
                kCIInputTimeKey: 1 - min(0.18, abs(recipe.clarity)),
            ])
        }
        if recipe.hsl.values.contains(where: { abs($0.hue) > 0.0001 || abs($0.saturation) > 0.0001 || abs($0.luminance) > 0.0001 }) {
            output = output.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": 16,
                "inputCubeData": colorCube(for: recipe),
            ])
        }
        if recipe.sharpening > 0 {
            output = output.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: recipe.sharpening * 1.5,
            ])
        }
        // Film look is last.
        if recipe.grainAmount > 0 {
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .cropped(to: output.extent)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0,
                    kCIInputContrastKey: 1 + recipe.grainRoughness,
                ])
                .applyingFilter("CIGaussianBlur", parameters: [
                    kCIInputRadiusKey: recipe.grainSoftness * 1.5,
                ])
            output = noise.applyingFilter("CISoftLightBlendMode", parameters: [
                kCIInputBackgroundImageKey: output,
            ]).applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: output,
                kCIInputTimeKey: 1 - min(0.32, recipe.grainAmount),
            ])
        }
        return output.cropped(to: image.extent)
    }

    /// Builds a small GPU lookup table for selective HSL. Core Image evaluates
    /// the table on the preview/export GPU, while this conversion runs only when
    /// a recipe changes (not once for every video pixel or frame).
    private static func colorCube(for recipe: CameraColorRecipe) -> Data {
        let key = (try? JSONEncoder().encode(recipe)) ?? Data()
        cubeLock.lock()
        if let cached = cubeCache[key] { cubeLock.unlock(); return cached }
        cubeLock.unlock()

        let dimension = 16
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let r = Double(red) / Double(dimension - 1)
                    let g = Double(green) / Double(dimension - 1)
                    let b = Double(blue) / Double(dimension - 1)
                    let adjusted = applyHSL(to: (r, g, b), recipe: recipe)
                    values += [Float(adjusted.0), Float(adjusted.1), Float(adjusted.2), 1]
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cubeLock.lock()
        if cubeCache.count >= 8 { cubeCache.removeAll(keepingCapacity: true) }
        cubeCache[key] = data
        cubeLock.unlock()
        return data
    }

    private static func applyHSL(to rgb: (Double, Double, Double), recipe: CameraColorRecipe) -> (Double, Double, Double) {
        var hsl = rgbToHSL(rgb)
        let originalHue = hsl.0
        for band in HSLBand.allCases {
            guard let adjustment = recipe.hsl[band],
                  abs(adjustment.hue) > 0.0001 || abs(adjustment.saturation) > 0.0001 || abs(adjustment.luminance) > 0.0001 else { continue }
            let weight = bandWeight(hue: originalHue, band: band, adjustment: adjustment)
            hsl.0 = (hsl.0 + adjustment.hue * 0.5 * weight).truncatingRemainder(dividingBy: 1)
            if hsl.0 < 0 { hsl.0 += 1 }
            hsl.1 = min(1, max(0, hsl.1 + adjustment.saturation * weight))
            hsl.2 = min(1, max(0, hsl.2 + adjustment.luminance * 0.5 * weight))
        }
        return hslToRGB(hsl)
    }

    private static func bandWeight(hue: Double, band: HSLBand, adjustment: HSLAdjustment) -> Double {
        let centers: [HSLBand: Double] = [.red: 0, .orange: 30, .yellow: 60, .green: 120,
                                           .aqua: 180, .blue: 240, .purple: 270, .magenta: 320]
        let center = (centers[band] ?? 0) / 360
        let distance = min(abs(hue - center), 1 - abs(hue - center))
        let radius = (35 + min(1, max(0, adjustment.range)) * 70) / 360
        guard distance < radius else { return 0 }
        let falloff = min(1, max(0.05, adjustment.falloff))
        let edge = max(0, 1 - distance / radius)
        return pow(edge, 1 / falloff)
    }

    private static func rgbToHSL(_ rgb: (Double, Double, Double)) -> (Double, Double, Double) {
        let maxValue = max(rgb.0, rgb.1, rgb.2)
        let minValue = min(rgb.0, rgb.1, rgb.2)
        let lightness = (maxValue + minValue) / 2
        let delta = maxValue - minValue
        guard delta > 0.000001 else { return (0, 0, lightness) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        if maxValue == rgb.0 { hue = ((rgb.1 - rgb.2) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxValue == rgb.1 { hue = (rgb.2 - rgb.0) / delta + 2 }
        else { hue = (rgb.0 - rgb.1) / delta + 4 }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, saturation, lightness)
    }

    private static func hslToRGB(_ hsl: (Double, Double, Double)) -> (Double, Double, Double) {
        guard hsl.1 > 0.000001 else { return (hsl.2, hsl.2, hsl.2) }
        let c = (1 - abs(2 * hsl.2 - 1)) * hsl.1
        let x = c * (1 - abs((hsl.0 * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = hsl.2 - c / 2
        let sector = Int(hsl.0 * 6)
        let value: (Double, Double, Double)
        switch sector {
        case 0: value = (c, x, 0)
        case 1: value = (x, c, 0)
        case 2: value = (0, c, x)
        case 3: value = (0, x, c)
        case 4: value = (x, 0, c)
        default: value = (c, 0, x)
        }
        return (value.0 + m, value.1 + m, value.2 + m)
    }
}
