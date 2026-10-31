import PhotosUI
import SwiftUI
import UIKit

private enum EditorStage: String, CaseIterable, Identifiable {
    case process = "Process"
    case hsl = "HSL"
    case film = "Film Look"
    var id: String { rawValue }
}

private enum EditorParameter: String, CaseIterable, Identifiable {
    case clarity = "Clarity"
    case sharpening = "Sharpening"
    case threshold = "Threshold"
    case contrast = "Contrast Curve"
    case preTint = "Magenta–Green Pre-Tint"
    case saturation = "Global Saturation"
    case hue = "Hue"
    case hslSaturation = "Saturation"
    case luminance = "Luminance"
    case colorRange = "Color Range"
    case falloff = "Falloff"
    case grainAmount = "Grain Amount"
    case grainSize = "Grain Size"
    case roughness = "Texture"
    case softness = "Softness"
    case pattern = "Grain Pattern"
    var id: String { rawValue }
}

struct CameraColorEditorView: View {
    @EnvironmentObject private var colors: CameraColorStore
    @Environment(\.dismiss) private var dismiss

    @State private var recipe: CameraColorRecipe
    let sourceSlot: Int?

    @State private var stage = EditorStage.process
    @State private var parameter = EditorParameter.clarity
    @State private var selectedBand = HSLBand.yellow
    @State private var chooserVisible = true
    @State private var showAffectedColor = false
    @State private var before = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoData: Data?
    @State private var showSave = false
    @State private var gestureStartAmount: Double?
    @State private var gestureStartParameter = 0

    init(recipe: CameraColorRecipe, sourceSlot: Int?) {
        _recipe = State(initialValue: recipe)
        self.sourceSlot = sourceSlot
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            photo
                .padding(.horizontal, 12)
                .padding(.top, 6)

            if stage == .hsl { hslSwatches.padding(.top, 10) }

            VStack(spacing: 7) {
                Text(parameter.rawValue.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(InCamTheme.ivory.opacity(0.7))
                Text(amountLabel)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                PrecisionRuler(value: amountBinding, range: amountRange, step: amountStep) { formatAmount($0) }
                    .frame(height: 55)
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)

            stageNavigation
                .padding(.horizontal, 16)
                .padding(.top, 10)

            HStack(spacing: 12) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Change Photo", systemImage: "photo")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .glass(in: Capsule())
                }
                Button { before.toggle() } label: {
                    Label(before ? "Before" : "After", systemImage: "rectangle.lefthalf.inset.filled")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .glass(in: Capsule(), emphasized: before)
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(16)
        }
        .background(InCamTheme.graphite.ignoresSafeArea())
        .foregroundStyle(InCamTheme.ivory)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { OrientationRequest.portrait() }
        .onChange(of: photoItem) { _, item in load(item) }
        .sheet(isPresented: $showSave) {
            SaveCameraColorView(recipe: recipe, initialSlot: sourceSlot) { dismiss() }
        }
    }

    private var editorHeader: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            Spacer()
            Text("Camera Colors").font(.system(size: 17, weight: .semibold, design: .rounded))
            Spacer()
            Button("Save") { showSave = true }
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(width: 54, height: 44)
        }
        .padding(.horizontal, 4)
    }

    private var photo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.28, blue: 0.18),
                                               Color(red: 0.08, green: 0.13, blue: 0.16), .black],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "mountain.2.fill")
                    .resizable().scaledToFit()
                    .frame(width: 150)
                    .foregroundStyle(.white.opacity(0.42))
            }
            if showAffectedColor {
                selectedBand.color.opacity(0.24)
                    .blendMode(.plusLighter)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            if chooserVisible {
                parameterChooser
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.12), lineWidth: 0.7))
        .aspectRatio(4 / 3, contentMode: .fit)
        .contentShape(Rectangle())
        .gesture(editorGesture)
    }

    private var parameterChooser: some View {
        VStack(spacing: 4) {
            ForEach(parameters, id: \.self) { item in
                Text(item.rawValue)
                    .font(.system(size: item == parameter ? 14 : 11, weight: item == parameter ? .bold : .medium, design: .rounded))
                    .foregroundStyle(item == parameter ? InCamTheme.ivory : InCamTheme.ivory.opacity(0.45))
                    .frame(height: item == parameter ? 28 : 20)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .glass(in: RoundedRectangle(cornerRadius: 18), emphasized: true)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private var editorGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height) + 7
                if horizontal {
                    if gestureStartAmount == nil { gestureStartAmount = amountBinding.wrappedValue }
                    chooserVisible = false
                    showAffectedColor = false
                    amountBinding.wrappedValue = min(amountRange.upperBound, max(amountRange.lowerBound,
                        (gestureStartAmount ?? 0) + Double(value.translation.width) * amountStep / 5))
                } else {
                    chooserVisible = true
                    let index = max(0, min(parameters.count - 1,
                        gestureStartParameter + Int((-value.translation.height / 34).rounded())))
                    parameter = parameters[index]
                }
            }
            .onEnded { _ in
                gestureStartAmount = nil
                gestureStartParameter = parameters.firstIndex(of: parameter) ?? 0
                withAnimation(.easeOut(duration: 0.15)) { chooserVisible = true }
            }
    }

    private var hslSwatches: some View {
        HStack(spacing: 9) {
            ForEach(HSLBand.allCases) { band in
                Button {
                    selectedBand = band
                    showAffectedColor = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { showAffectedColor = false }
                } label: {
                    Circle().fill(band.color)
                        .frame(width: band == selectedBand ? 28 : 23, height: band == selectedBand ? 28 : 23)
                        .overlay(Circle().stroke(InCamTheme.ivory, lineWidth: band == selectedBand ? 2 : 0))
                }
            }
            Button { showAffectedColor.toggle() } label: {
                Image(systemName: showAffectedColor ? "eye.fill" : "eye")
                    .frame(width: 30, height: 30)
            }
        }
        .buttonStyle(PressScaleStyle())
    }

    private var stageNavigation: some View {
        HStack(spacing: 0) {
            ForEach(EditorStage.allCases) { item in
                Button {
                    stage = item
                    parameter = parameters(for: item).first!
                    chooserVisible = true
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: stage == item ? .bold : .medium, design: .rounded))
                        .foregroundStyle(stage == item ? InCamTheme.ivory : InCamTheme.ivory.opacity(0.48))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(stage == item ? .white.opacity(0.09) : .clear, in: Capsule())
                }
            }
        }
        .padding(3)
        .glass(in: Capsule())
    }

    private var parameters: [EditorParameter] { parameters(for: stage) }
    private func parameters(for stage: EditorStage) -> [EditorParameter] {
        switch stage {
        case .process: return [.clarity, .sharpening, .threshold, .contrast, .preTint, .saturation]
        case .hsl: return [.hue, .hslSaturation, .luminance, .colorRange, .falloff]
        case .film: return [.grainAmount, .grainSize, .roughness, .softness, .pattern]
        }
    }

    private var amountRange: ClosedRange<Double> {
        parameter == .pattern ? 0...2 : -1...1
    }
    private var amountStep: Double { parameter == .pattern ? 1 : 0.01 }
    private var amountLabel: String { formatAmount(amountBinding.wrappedValue) }

    private func formatAmount(_ value: Double) -> String {
        if parameter == .pattern { return ["Fine", "Classic", "Coarse"][max(0, min(2, Int(value.rounded())))] }
        return String(format: "%+.0f", value * 100)
    }

    private var amountBinding: Binding<Double> {
        Binding(get: { value(for: parameter) }, set: { setValue($0, for: parameter) })
    }

    private func value(for parameter: EditorParameter) -> Double {
        let hsl = recipe.hsl[selectedBand] ?? HSLAdjustment()
        switch parameter {
        case .clarity: return recipe.clarity
        case .sharpening: return recipe.sharpening
        case .threshold: return recipe.threshold
        case .contrast: return recipe.contrast
        case .preTint: return recipe.preTint
        case .saturation: return recipe.saturation
        case .hue: return hsl.hue
        case .hslSaturation: return hsl.saturation
        case .luminance: return hsl.luminance
        case .colorRange: return hsl.range
        case .falloff: return hsl.falloff
        case .grainAmount: return recipe.grainAmount
        case .grainSize: return recipe.grainSize
        case .roughness: return recipe.grainRoughness
        case .softness: return recipe.grainSoftness
        case .pattern: return Double(["Fine", "Classic", "Coarse"].firstIndex(of: recipe.grainPattern) ?? 0)
        }
    }

    private func setValue(_ value: Double, for parameter: EditorParameter) {
        var hsl = recipe.hsl[selectedBand] ?? HSLAdjustment()
        switch parameter {
        case .clarity: recipe.clarity = value
        case .sharpening: recipe.sharpening = value
        case .threshold: recipe.threshold = value
        case .contrast: recipe.contrast = value
        case .preTint: recipe.preTint = value
        case .saturation: recipe.saturation = value
        case .hue: hsl.hue = value; recipe.hsl[selectedBand] = hsl
        case .hslSaturation: hsl.saturation = value; recipe.hsl[selectedBand] = hsl
        case .luminance: hsl.luminance = value; recipe.hsl[selectedBand] = hsl
        case .colorRange: hsl.range = value; recipe.hsl[selectedBand] = hsl
        case .falloff: hsl.falloff = value; recipe.hsl[selectedBand] = hsl
        case .grainAmount: recipe.grainAmount = value
        case .grainSize: recipe.grainSize = value
        case .roughness: recipe.grainRoughness = value
        case .softness: recipe.grainSoftness = value
        case .pattern: recipe.grainPattern = ["Fine", "Classic", "Coarse"][max(0, min(2, Int(value.rounded())))]
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task { photoData = try? await item.loadTransferable(type: Data.self) }
    }

    private var displayedImage: UIImage? {
        guard let photoData, let source = UIImage(data: photoData) else { return nil }
        guard !before, let ci = CIImage(image: source) else { return source }
        let rendered = RecipeRenderer.render(ci, recipe: recipe)
        guard let cg = RecipeRenderer.context.createCGImage(rendered, from: rendered.extent) else { return source }
        return UIImage(cgImage: cg, scale: source.scale, orientation: source.imageOrientation)
    }
}

private struct SaveCameraColorView: View {
    @EnvironmentObject private var colors: CameraColorStore
    @Environment(\.dismiss) private var dismiss
    @State var recipe: CameraColorRecipe
    @State private var selectedSlot: Int
    let onSaved: () -> Void
    let previewPhoto: UIImage?

    init(recipe: CameraColorRecipe, initialSlot: Int?, previewPhoto: UIImage? = nil, onSaved: @escaping () -> Void) {
        _recipe = State(initialValue: recipe)
        _selectedSlot = State(initialValue: initialSlot ?? 0)
        self.onSaved = onSaved
        self.previewPhoto = previewPhoto
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 18) {
                RecipeImagePreview(recipe: recipe, photo: previewPhoto).frame(height: 150)
                TextField("Recipe name", text: $recipe.name)
                    .textFieldStyle(.roundedBorder)
                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Array(colors.slots.indices), id: \.self) { index in
                        Button { selectedSlot = index } label: {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .frame(width: 44, height: 44)
                                .background(selectedSlot == index ? InCamTheme.ivory : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(selectedSlot == index ? .black : InCamTheme.ivory)
                        }
                    }
                    Button { selectedSlot = colors.addCustomColor(); recipe.name = colors.slots[selectedSlot].name } label: {
                        Image(systemName: "plus").frame(width: 44, height: 44)
                    }.accessibilityLabel("Add custom color slot")
                }
                }
                Text("Replaces “\(colors.slots[selectedSlot].name)” in slot \(selectedSlot + 1). The sample photo is not changed.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    colors.save(recipe, to: selectedSlot)
                    dismiss()
                    onSaved()
                } label: {
                    Text("Save to slot \(selectedSlot + 1)")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(InCamTheme.ivory, in: Capsule())
                        .foregroundStyle(.black)
                }
                Spacer()
            }
            .padding(18)
            }
            .background(InCamTheme.graphite.ignoresSafeArea())
            .navigationTitle("Save Camera Color")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if recipe.name == "Custom Color" { recipe.name = colors.slots[selectedSlot].name }
            }
            .onChange(of: selectedSlot) { _, index in
                if recipe.name.hasPrefix("Custom Color #") { recipe.name = colors.slots[index].name }
            }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }
}

private enum OrientationRequest {
    static func portrait() {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }
}

/// On-camera recipe editing. Capture rendering is deliberately not implied here.
@MainActor
final class ColorDockControls: ObservableObject {
    @Published var recipe: CameraColorRecipe {
        didSet {
            // Saved drafts from earlier builds can contain much stronger
            // numbers. Re-clamp every assignment before it reaches preview.
            var sanitized = recipe
            Self.sanitize(&sanitized)
            if sanitized != recipe {
                recipe = sanitized
            } else {
                persist()
            }
        }
    }
    @Published var selection = "Clarity"
    @Published var band = HSLBand.yellow
    @Published var axis = "Hue"
    // Camera Colors now owns saved color modes directly. The old CC page
    // remains in the data model for compatibility but is no longer a route.
    let sections = ["Clarity", "Saturation", "Contrast", "Color Mix"]
    @Published var loadedCustomSlot: Int?
    /// Camera Colors can be active without opening its detailed mixer. This
    /// makes the dock a direct mode selector during normal shooting.
    @Published var cameraColorsEnabled = false
    let axes = ["Hue", "Saturation", "Luminance"]

    /// The shooting UI identifies the active saved slot, not the generic
    /// editing page, so it is always clear which Custom Color is changing.
    var activeCameraColorTitle: String {
        "CC\((loadedCustomSlot ?? 0) + 1)"
    }

    init() {
        let data = UserDefaults.standard.data(forKey: "incam.color-dock.draft.v1") ?? Data()
        var restored = (try? JSONDecoder().decode(CameraColorRecipe.self, from: data)) ?? CameraColorRecipe(name: "Custom Color")
        // Older drafts used a much stronger response. Clamp them as they load
        // so a previously saved grade cannot blow out the live camera image.
        Self.sanitize(&restored)
        recipe = restored
    }
    func persist() {
        if let data = try? JSONEncoder().encode(recipe) { UserDefaults.standard.set(data, forKey: "incam.color-dock.draft.v1") }
    }
    func changePage(_ delta: Int) {
        let index = sections.firstIndex(of: selection) ?? 0
        selection = sections[min(sections.count - 1, max(0, index + delta))]
    }
    func changeAxis(_ delta: Int) {
        let index = axes.firstIndex(of: axis) ?? 0
        axis = axes[min(axes.count - 1, max(0, index + delta))]
    }

    /// Tapping Camera Colors opens the picker; it deliberately does not
    /// rotate a look. A vertical scrub in that picker is the only way to
    /// change slots, which prevents accidental recipe changes while filming.
    func beginCameraColorSelection(using savedSlots: [CameraColorRecipe?]) {
        cameraColorsEnabled = true
        if loadedCustomSlot == nil { loadCustomColor(at: 0, savedSlots: savedSlots) }
    }

    func selectCustomColor(at index: Int, savedSlots: [CameraColorRecipe?]) {
        guard savedSlots.indices.contains(index) else { return }
        cameraColorsEnabled = true
        loadCustomColor(at: index, savedSlots: savedSlots)
    }

    /// The plus tile starts a fresh unsaved draft. It reserves the next CC
    /// label for the eventual Save action without creating background work.
    func prepareNewCustomColor(at index: Int) {
        loadedCustomSlot = index
        cameraColorsEnabled = true
        recipe = CameraColorRecipe(name: "CC\(index + 1)")
    }

    private func loadCustomColor(at index: Int, savedSlots: [CameraColorRecipe?]) {
        loadedCustomSlot = index
        if savedSlots.indices.contains(index), let saved = savedSlots[index] {
            recipe = saved
        } else {
            recipe = CameraColorRecipe(name: "Custom Color \(index + 1)")
        }
    }
    /// The visible RESET control returns the entire current draft to neutral:
    /// Clarity, Saturation, Contrast, every H/S/L band, and other draft-only
    /// processing values. Saved Custom Color slots remain untouched.
    func resetAllCameraColors() {
        var neutral = CameraColorRecipe(name: recipe.name)
        neutral.id = recipe.id
        recipe = neutral
        loadedCustomSlot = nil
    }
    /// Double-tap reset for the active basic color dial. It preserves all
    /// other adjustments and saved Custom Colors.
    func resetCurrentBasicAdjustment() {
        switch selection {
        case "Clarity": recipe.clarity = 0
        case "Saturation": recipe.saturation = 0
        case "Contrast": recipe.contrast = 0
        default: break
        }
    }

    /// The on-screen ruler deliberately remains -7…+7, while each step maps
    /// to a subtle camera-grade adjustment. This preserves familiar numbers
    /// without letting a single swipe turn footage white, black, or neon.
    private func step(for section: String) -> Double {
        // Keep the -7...+7 dial, but make green and the other hue ranges
        // visibly responsive without requiring extreme scrubbing.
        if section == "Color Mix" { return axis == "Hue" ? 0.022 : 0.040 }
        switch section {
        case "Clarity": return 0.055
        case "Saturation": return 0.04
        case "Contrast": return 0.015
        default: return 0.025
        }
    }

    var displayAmount: Double { min(7, max(-7, amount / step(for: selection))) }

    func setDisplayAmount(_ value: Double) {
        amount = value * step(for: selection)
    }

    func displayAmount(for section: String) -> Double {
        let raw: Double
        switch section {
        case "Clarity": raw = recipe.clarity
        case "Saturation": raw = recipe.saturation
        case "Contrast": raw = recipe.contrast
        default: raw = 0
        }
        return min(7, max(-7, raw / step(for: section)))
    }

    func displayHSLAmount(axis: String, rawValue: Double) -> Double {
        rawValue / (axis == "Hue" ? 0.0125 : 0.025)
    }

    private static func sanitize(_ recipe: inout CameraColorRecipe) {
        // Recipe pre-tint was the source of a second, unstable tint path.
        // Hardware White Balance owns Tint now, so migrate old drafts to zero.
        recipe.preTint = 0
        // Clarity has a wider usable range than Saturation: positive values
        // add restrained luminance detail while negative values soften. The
        // visible −7…+7 scale stays exactly the same.
        recipe.clarity = min(0.40, max(-0.40, recipe.clarity))
        recipe.saturation = min(0.28, max(-0.28, recipe.saturation))
        recipe.contrast = min(0.105, max(-0.105, recipe.contrast))
        for band in HSLBand.allCases {
            guard var adjustment = recipe.hsl[band] else { continue }
            adjustment.hue = min(0.09, max(-0.09, adjustment.hue))
            adjustment.saturation = min(0.18, max(-0.18, adjustment.saturation))
            adjustment.luminance = min(0.18, max(-0.18, adjustment.luminance))
            recipe.hsl[band] = adjustment
        }
    }
    var amount: Double {
        get {
            switch selection {
            case "Clarity": return recipe.clarity
            case "Saturation": return recipe.saturation
            case "Contrast": return recipe.contrast
            default:
                let hsl = recipe.hsl[band] ?? HSLAdjustment()
                return axis == "Hue" ? hsl.hue : (axis == "Saturation" ? hsl.saturation : hsl.luminance)
            }
        }
        set {
            // Keep the on-camera grade usable while it is adjusted over a live
            // image. Full-strength ±1 values can clip channels into unusable
            // colors on phone footage.
            let bounds: ClosedRange<Double>
            switch selection {
            case "Clarity": bounds = -0.40...0.40
            case "Saturation": bounds = -0.28...0.28
            case "Contrast": bounds = -0.105...0.105
            default: bounds = axis == "Hue" ? -0.09...0.09 : -0.18...0.18
            }
            let value = min(bounds.upperBound, max(bounds.lowerBound, newValue))
            switch selection {
            case "Clarity": recipe.clarity = value
            case "Saturation": recipe.saturation = value
            case "Contrast": recipe.contrast = value
            default:
                var hsl = recipe.hsl[band] ?? HSLAdjustment()
                if axis == "Hue" { hsl.hue = value }
                else if axis == "Saturation" { hsl.saturation = value }
                else { hsl.luminance = value }
                recipe.hsl[band] = hsl
            }
        }
    }
}

struct CameraColorDock: View {
    @EnvironmentObject private var camera: CameraController
    @EnvironmentObject private var colors: CameraColorStore
    @ObservedObject var controls: ColorDockControls
    @Binding var expanded: Bool
    @State private var showPresetPicker = false
    @State private var colorLongPressTriggered = false
    private let sections = ["Clarity", "Saturation", "Contrast", "Color Mix"]

    private var highlightedSection: String {
        controls.selection == "Custom Colors" ? "Color Mix" : controls.selection
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { proxy in
                // Camera Colors receives 1.5× the width of one basic dial.
                // That prevents the title from truncating while keeping the
                // three simple controls compact and legible.
                let dividerFootprint: CGFloat = 27
                let usableWidth = max(0, proxy.size.width - dividerFootprint * 3)
                let basicWidth = usableWidth / 4.5
                let colorsWidth = basicWidth * 1.5
                HStack(spacing: 0) {
                    ForEach(sections, id: \.self) { item in
                        if item != sections.first { Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 24).padding(.horizontal, 13) }
                        Button {
                        if item == "Color Mix" {
                            // A successful long press opens HSL. Do not let
                            // the Button's release action immediately replace
                            // it with the normal CC-slot picker.
                            if colorLongPressTriggered {
                                colorLongPressTriggered = false
                                return
                            }
                            // A normal tap reveals only the saved looks. It
                            // never rotates through a hidden numbered list.
                            controls.cameraColorsEnabled = true
                            showPresetPicker.toggle()
                            expanded = false
                        } else {
                            showPresetPicker = false
                            controls.selection = item
                            expanded = true
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Text(item == "Color Mix" ? "CAMERA COLORS" : item.uppercased())
                                .font(.system(size: item == "Color Mix" ? 11 : 10, weight: .semibold))
                                .lineLimit(1).minimumScaleFactor(0.78)
                            if item != "Color Mix" {
                                // Values remain visible at rest so there is
                                // never any ambiguity about the active grade.
                                Text(amountLabel(item: item)).monospacedDigit()
                                    .font(.system(size: 11, weight: .medium))
                            } else if controls.cameraColorsEnabled {
                                Text(controls.activeCameraColorTitle.uppercased())
                                    .font(.system(size: 8, weight: .medium))
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        .frame(width: item == "Color Mix" ? colorsWidth : basicWidth, height: 36)
                        .contentShape(Rectangle())
                            // Yellow follows the finger during a horizontal
                            // scroll, then remains on the page that was chosen.
                            .foregroundStyle(highlightedSection == item ? .yellow : InCamTheme.ivory)
                    }
                        .disabled(camera.logModeEnabled && ["Saturation", "Contrast"].contains(item))
                        .opacity(camera.logModeEnabled && ["Saturation", "Contrast"].contains(item) ? 0.35 : 1)
                        .accessibilityLabel(item == "Color Mix" ? "Camera Colors" : item)
                        .accessibilityValue(item == "Color Mix" ? (controls.cameraColorsEnabled ? controls.recipe.name : "Off") : (expanded && controls.selection == item ? amountLabel(item: item) : ""))
                        .accessibilityHint(item == "Color Mix" ? "Tap to open the Custom Colors picker on the right." : "Opens the \(item) adjustment on the right")
                        .accessibilityAddTraits(expanded && controls.selection == item ? .isSelected : [])
                        .accessibilityIdentifier("colorDock.\(item)")
                        .onLongPressGesture(minimumDuration: 0.35, pressing: { pressing in
                            // Reset only at the start of a new touch. Keeping
                            // the flag through release lets the Button action
                            // above recognize and consume the held gesture.
                            if pressing && item == "Color Mix" {
                                colorLongPressTriggered = false
                            }
                        }, perform: {
                            // Holding Camera Colors is the deliberate route
                            // into the detailed HSL editor for a new recipe.
                            guard item == "Color Mix" else { return }
                            colorLongPressTriggered = true
                            showPresetPicker = false
                            controls.cameraColorsEnabled = true
                            controls.selection = "Color Mix"
                            expanded = true
                        })
                        .simultaneousGesture(item == "Color Mix" ? nil : TapGesture(count: 2).onEnded {
                            // A dock-level double tap restores only the value
                            // under the finger—Clarity, Saturation, or Contrast.
                            controls.selection = item
                            controls.resetCurrentBasicAdjustment()
                            expanded = true
                        })
                    }
                }
            }
            .frame(height: 36)
            .overlay(alignment: .top) {
                if showPresetPicker {
                    CameraColorPresetStrip(
                        presets: colors.quickSlots.enumerated().compactMap { index, recipe in
                            recipe.map { CameraColorModeEntry(index: index, recipe: $0) }
                        },
                        onSelect: { index in
                            controls.selectCustomColor(at: index, savedSlots: colors.quickSlots)
                            showPresetPicker = false
                            // Selecting a saved CC opens that CC's palette
                            // on the mousepad instead of merely loading an
                            // invisible recipe in the background.
                            controls.selection = "Color Mix"
                            expanded = true
                        },
                        onCustomize: {
                            // The plus tile opens the next unsaved CC draft.
                            // It is stored only when the person presses SAVE.
                            guard let nextSlot = colors.quickSlots.firstIndex(where: { $0 == nil }) else {
                                return
                            }
                            controls.prepareNewCustomColor(at: nextSlot)
                            controls.selection = "Color Mix"
                            showPresetPicker = false
                            expanded = true
                        }
                    )
                    .offset(y: -62)
                    .zIndex(10)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous), emphasized: expanded)
        .buttonStyle(.plain)
        .accessibilityHint("Tap an adjustment to open it on the right.")
    }

    private func amountLabel(item: String) -> String {
        String(format: "%+.0f", controls.displayAmount(for: item).rounded())
    }

}

/// A compact dock-local picker, deliberately replacing the former full-screen
/// recipe browser. It reveals only nearby color modes and makes no extra work
/// until the user explicitly holds Camera Colors.
private struct CameraColorPresetStrip: View {
    let presets: [CameraColorModeEntry]
    let onSelect: (Int) -> Void
    let onCustomize: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            ForEach(presets) { preset in
                Button { onSelect(preset.index) } label: {
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.yellow.opacity(0.25))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(.yellow.opacity(0.7), lineWidth: 1))
                            .frame(width: 25, height: 19)
                        // Slot names stay short in the shooting interface.
                        // Recipe names remain available in detailed editing.
                        Text("CC\(preset.index + 1)")
                            .font(.system(size: 7, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(InCamTheme.ivory)
                    .frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.35), lineWidth: 0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Load CC \(preset.index + 1)")
            }
            Button(action: onCustomize) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: 44, height: 44)
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(.yellow.opacity(0.75), lineWidth: 0.9))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add a new custom color")
        }
        // Deliberately no tray/material behind the CC tiles: they float over
        // the live camera image and do not block the viewfinder or gallery.
        .accessibilityIdentifier("customColors.presetPicker")
    }
}

private struct CameraColorModeEntry: Identifiable {
    let index: Int
    let recipe: CameraColorRecipe
    var id: Int { index }
}

struct RightColorAdjustment: View {
    @ObservedObject var controls: ColorDockControls
    var body: some View {
        if controls.selection == "Color Mix" {
            ColorMixDials(controls: controls)
        } else if controls.selection == "Custom Colors" {
            CustomColorSlots(controls: controls)
        } else {
        // Anchor the readout itself to Record's center, independent of headers and previews.
        ZStack {
        PrecisionRuler(value: Binding(get: { controls.displayAmount.rounded() }, set: { controls.setDisplayAmount($0) }), range: -7...7, step: 1, verticalHeight: 112) {
            String(format: "%+.0f", $0)
        }
        .environment(\.verticalCameraRuler, true)
        .frame(width: 56, height: 112)
            if controls.selection == "Color Mix" {
                RainbowColorSelector(selection: $controls.band,
                                     hue: Binding(get: { controls.recipe.hsl[controls.band]?.hue ?? 0 }, set: { value in
                                         var hsl = controls.recipe.hsl[controls.band] ?? HSLAdjustment()
                                         hsl.hue = value
                                         controls.recipe.hsl[controls.band] = hsl
                                     }), onHueBegin: { controls.axis = "Hue" })
                    .frame(width: 40, height: 112)
                    .offset(x: -52)
            }
            VStack(spacing: 2) {
            Text(controls.selection).font(.system(size: 10, weight: .medium))
                .accessibilityIdentifier("colorDock.adjustmentTitle")
                .lineLimit(1).minimumScaleFactor(0.9).frame(height: 28)
                .frame(maxWidth: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 16).onEnded { drag in
                    let movement = abs(drag.translation.width) > abs(drag.translation.height) ? drag.translation.width : drag.translation.height
                    controls.changePage(movement < 0 ? 1 : -1)
                })
                .accessibilityHint("Swipe to change color adjustment")
            if controls.selection == "Color Mix" {
                HStack(spacing: 3) {
                    ForEach(controls.axes, id: \.self) { axis in
                        Button { controls.axis = axis } label: {
                            VStack(spacing: 3) {
                                Text(String(axis.prefix(3)).uppercased()).font(.system(size: 9, weight: .semibold))
                                Text(axisValue(axis)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                            }
                            .frame(width: 30, height: 44)
                            .contentShape(Rectangle())
                            .foregroundStyle(controls.axis == axis ? .yellow : InCamTheme.ivory.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(axis)
                        .accessibilityValue(axisValue(axis))
                        .accessibilityAddTraits(controls.axis == axis ? .isSelected : [])
                        .accessibilityIdentifier("colorDock.axis.\(axis)")
                    }
                }
                .frame(width: 96)
            }
            }
            .frame(width: 64)
            .offset(y: controls.selection == "Color Mix" ? -101 : -78)
        }
        .frame(width: controls.selection == "Color Mix" ? 108 : 64, height: controls.selection == "Color Mix" ? 280 : 252)
        .foregroundStyle(InCamTheme.ivory)
        .shadow(color: .black.opacity(0.8), radius: 2, y: 1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("colorDock.rightAdjustment")
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            controls.resetCurrentBasicAdjustment()
        })
        }
    }

    private func axisValue(_ axis: String) -> String {
        let hsl = controls.recipe.hsl[controls.band] ?? HSLAdjustment()
        let value = axis == "Hue" ? hsl.hue : (axis == "Saturation" ? hsl.saturation : hsl.luminance)
        return String(format: "%+.0f", controls.displayHSLAmount(axis: axis, rawValue: value).rounded())
    }
}

/// Six explicit color ranges and three independent, transparent HSL rulers.
private struct ColorMixDials: View {
    @EnvironmentObject private var colors: CameraColorStore
    @ObservedObject var controls: ColorDockControls
    @State private var confirmedAction: String?
    @State private var colorDragStartIndex: Int?
    @State private var colorDragLastIndex: Int?
    // Every available HSL range participates in the live selector; omitting
    // Orange/Purple made it impossible to settle precisely between primaries.
    private let bands = HSLBand.allCases

    var body: some View {
        ZStack {
            Text(controls.activeCameraColorTitle).font(.system(size: 10, weight: .medium))
                .frame(width: 96, height: 28).offset(y: -78)
                .accessibilityIdentifier("colorDock.adjustmentTitle")
            colorSelector
            colorActions
            axisSlider
            axisOptions
            Color.clear.frame(width: 112, height: 280).allowsHitTesting(false)
        }
        .frame(width: 112, height: 280)
        .buttonStyle(.plain).foregroundStyle(InCamTheme.ivory)
        .accessibilityIdentifier("colorDock.rightAdjustment")
    }

    private var colorSelector: some View {
            ZStack(alignment: .leading) {
                LinearGradient(colors: bands.map(\.color), startPoint: .leading, endPoint: .trailing)
                    .frame(width: 92, height: 5).clipShape(Capsule())
                Circle().fill(controls.band.color).overlay(Circle().stroke(.white, lineWidth: 1))
                    .frame(width: 10, height: 10)
                    .offset(x: CGFloat(bands.firstIndex(of: controls.band) ?? 0) / CGFloat(max(1, bands.count - 1)) * 82)
            }
            // The visible line stays compact, while this larger isolated
            // touch area lets a held drag select a band without competing
            // with the nearby Hue/Sat/Lum ruler.
            .frame(width: 108, height: 44).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                // A drag that begins on this strip continues to own range
                // selection even after the finger leaves it.  This is the
                // important Apple-style fine-scrub behavior: moving vertically
                // away must *not* cancel selection merely because the vertical
                // distance is now larger than the horizontal distance.
                if colorDragStartIndex == nil { colorDragStartIndex = bands.firstIndex(of: controls.band) ?? 0 }
                let start = colorDragStartIndex ?? 0
                // Like Apple's fine scrubbing, moving away from the strip
                // steadily increases the horizontal travel required for each
                // color range.  Close = quick range changes; far = precise,
                // slower range changes.  The value is deliberately bounded so
                // a long held drag still reaches every color.
                let distance = abs(drag.translation.height)
                // Keep distant scrubbing precise, but never make the end
                // colors unreachable in a normal thumb sweep. The previous
                // 144-point maximum required more than 1,000 points to cross
                // the eight ranges; 38 points keeps far scrubbing controlled
                // while allowing the complete palette in one gesture.
                let pointsPerRange = 12 + min(26, distance * 0.22)
                let offset = Int((drag.translation.width / pointsPerRange).rounded())
                let index = min(bands.count - 1, max(0, start + offset))
                // Avoid assigning the same band on every drag tick. That
                // keeps the picker responsive even when a held finger is
                // stationary or moving only vertically.
                if colorDragLastIndex != index {
                    controls.band = bands[index]
                    colorDragLastIndex = index
                }
            }.onEnded { _ in
                colorDragStartIndex = nil
                colorDragLastIndex = nil
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Color range")
            .accessibilityValue(controls.band.rawValue)
            .accessibilityAdjustableAction { direction in
                let index = bands.firstIndex(of: controls.band) ?? 0
                controls.band = bands[min(bands.count - 1, max(0, index + (direction == .increment ? 1 : -1)))]
            }
            .accessibilityIdentifier("colorDock.colorPages")
            .offset(y: -48)

    }

    private var colorActions: some View {
        VStack(spacing: 5) {
            Button {
                controls.resetAllCameraColors()
                confirm("RESET")
            } label: {
                Text("RESET")
                    .foregroundStyle(confirmedAction == "RESET" ? .yellow : InCamTheme.ivory)
                    .frame(width: 92, height: 32)
            }
                .accessibilityLabel("Reset all Camera Colors")
                .accessibilityHint("Returns the complete current color draft to neutral")
            Button {
                saveCurrentMode()
                confirm("SAVE")
            } label: {
                Text("SAVE")
                    .foregroundStyle(confirmedAction == "SAVE" ? .yellow : InCamTheme.ivory)
                    .frame(width: 92, height: 32)
            }
                .accessibilityLabel("Save current Camera Colors mode")
        }
        // Centered controls match the wider color-range strip and sit below
        // the HUE/SAT/LUM selector, leaving a deliberate touch-safe gap.
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .frame(width: 92)
        .buttonStyle(.plain)
        .offset(y: 100)
    }

    /// A short yellow confirmation is clearer than permanently coloring
    /// destructive and save controls; their resting state stays white.
    private func confirm(_ action: String) {
        confirmedAction = action
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard confirmedAction == action else { return }
            confirmedAction = nil
        }
    }

    private var axisSlider: some View {
            ZStack(alignment: .bottom) {
                LinearGradient(colors: (0...12).map { gradientColor(Double($0) / 12) },
                               startPoint: .bottom, endPoint: .top)
                    .frame(width: 5, height: 84).clipShape(Capsule())
                Capsule().fill(.white).frame(width: 11, height: 3)
                    .offset(y: -CGFloat((controls.displayAmount + 7) / 14) * 81)
            }
            // A generous but isolated hit zone makes vertical adjustment easy
            // without stealing the horizontal color-range gesture on the left.
            .frame(width: 34, height: 92).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard abs(drag.translation.height) >= abs(drag.translation.width) else { return }
                let progress = min(1.0, max(0.0, 1 - Double(drag.location.y) / 84.0))
                controls.setDisplayAmount((progress * 14).rounded() - 7)
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(controls.axis)
            .accessibilityValue(String(format: "%+.0f", controls.displayAmount.rounded()))
            .accessibilityAdjustableAction { direction in
                controls.setDisplayAmount(controls.displayAmount + (direction == .increment ? 1 : -1))
            }
            .accessibilityIdentifier("colorDock.axis.\(controls.axis)")
            .offset(x: 27, y: 12)

    }

    private var axisOptions: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(controls.axes, id: \.self) { axis in
                    Button { controls.axis = axis } label: {
                        Text(axis == "Hue" ? "HUE" : axis == "Saturation" ? "SAT" : "LUM")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(controls.axis == axis ? .yellow : InCamTheme.ivory.opacity(0.65))
                            .frame(width: 44, height: 28, alignment: .leading).contentShape(Rectangle())
                    }.accessibilityIdentifier("colorDock.selectAxis.\(axis)")
                }
            }.offset(x: -20, y: 12)

    }

    private func saveCurrentMode() {
        let index = controls.loadedCustomSlot ?? colors.quickSlots.firstIndex(where: { $0 == nil }) ?? 0
        guard colors.quickSlots.indices.contains(index) else { return }
        var saved = controls.recipe
        saved.name = "CC\(index + 1)"
        colors.saveQuick(saved, to: index)
        controls.loadedCustomSlot = index
    }

    private func gradientColor(_ progress: Double) -> Color {
        if controls.axis == "Luminance" { return Color(white: progress) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        UIColor(controls.band.color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if controls.axis == "Hue" {
            let shifted = (Double(hue) + progress - 0.5 + 1).truncatingRemainder(dividingBy: 1)
            return Color(hue: shifted, saturation: 1, brightness: 1)
        }
        return Color(hue: Double(hue), saturation: progress, brightness: Double(brightness))
    }
}

private struct CustomColorSlots: View {
    @EnvironmentObject private var colors: CameraColorStore
    @ObservedObject var controls: ColorDockControls
    @State private var pendingSave: Int?
    @State private var scrubStartIndex: Int?
    @State private var scrubLastIndex: Int?

    var body: some View {
        ZStack {
            Text("Custom Colors").font(.system(size: 10, weight: .medium))
                .frame(width: 96, height: 28).offset(y: -78)
                .accessibilityIdentifier("colorDock.adjustmentTitle")
            VStack(spacing: 1) {
                ForEach(colors.quickSlots.indices, id: \.self) { index in
                    Button {
                        if colors.quickSlots[index] == nil {
                            colors.saveQuick(controls.recipe, to: index)
                            controls.selectCustomColor(at: index, savedSlots: colors.quickSlots)
                        } else if controls.loadedCustomSlot == index {
                            pendingSave = index
                        } else {
                            controls.selectCustomColor(at: index, savedSlots: colors.quickSlots)
                        }
                    } label: {
                        HStack {
                            Text("\(index + 1)").monospacedDigit()
                            Spacer()
                            Text(colors.quickSlots[index] == nil ? "+ Add" : "Saved")
                        }.font(.system(size: 9, weight: .medium))
                            .foregroundStyle(controls.loadedCustomSlot == index ? .yellow : InCamTheme.ivory)
                            .frame(width: 86, height: 19).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Custom color slot \(index + 1)")
                    .accessibilityValue(colors.quickSlots[index] == nil ? "Empty. Tap to save current settings" : controls.loadedCustomSlot == index ? "Loaded. Tap to save changes" : "Saved. Tap to load")
                    .accessibilityIdentifier("customColors.slot.\(index)")
                }
            }
            Button { controls.selection = "Color Mix" } label: {
                Text("EDIT MIX").font(.system(size: 9, weight: .semibold))
                    .frame(width: 96, height: 34)
            }.offset(y: 100)
        }
        .frame(width: 112, height: 252).buttonStyle(.plain)
        .foregroundStyle(InCamTheme.ivory)
        .simultaneousGesture(DragGesture(minimumDistance: 3)
            .onChanged { drag in
                // Vertical scrubbing advances through the seven saved slots.
                // It remains active after the thumb moves away from a row so
                // the slot change is deliberate and controllable.
                let start = scrubStartIndex ?? controls.loadedCustomSlot ?? 0
                scrubStartIndex = start
                let offset = Int((-drag.translation.height / 20).rounded())
                let index = min(colors.quickSlots.count - 1, max(0, start + offset))
                if scrubLastIndex != index {
                    controls.selectCustomColor(at: index, savedSlots: colors.quickSlots)
                    scrubLastIndex = index
                }
            }
            .onEnded { _ in
                scrubStartIndex = nil
                scrubLastIndex = nil
            })
        .confirmationDialog("Save current adjustments to this slot?", isPresented: Binding(
            get: { pendingSave != nil }, set: { if !$0 { pendingSave = nil } })) {
                if let index = pendingSave {
                    Button("Save to slot \(index + 1)", role: .destructive) {
                        colors.saveQuick(controls.recipe, to: index)
                        pendingSave = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingSave = nil }
        } message: { Text("This replaces the saved color settings in this slot.") }
    }
}

private struct RainbowColorSelector: View {
    @Binding var selection: HSLBand
    @Binding var hue: Double
    let onHueBegin: () -> Void
    @State private var startingHue: Double?
    private var bands: [HSLBand] { HSLBand.allCases }
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(colors: bands.map(\.color), startPoint: .top, endPoint: .bottom)
                    .frame(width: 14).clipShape(Capsule())
                Circle().fill(selection.color).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(x: proxy.size.width / 2,
                              y: 11 + CGFloat(bands.firstIndex(of: selection) ?? 0) / CGFloat(bands.count - 1) * (proxy.size.height - 22))
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .gesture(LongPressGesture(minimumDuration: 0.35, maximumDistance: 10)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .exclusively(before: DragGesture(minimumDistance: 3))
                    .onChanged { gesture in
                        switch gesture {
                        case .first(.second(true, let drag)):
                            if startingHue == nil { startingHue = hue; onHueBegin() }
                            if let drag, let startingHue {
                                let value = startingHue - Double(drag.translation.height) / 120
                                hue = min(1, max(-1, (value * 100).rounded() / 100))
                            }
                        case .second(let drag): select(at: drag.location.y, height: proxy.size.height)
                        default: break
                        }
                    }
                    .onEnded { _ in startingHue = nil })
                .simultaneousGesture(SpatialTapGesture().onEnded { select(at: $0.location.y, height: proxy.size.height) })
        }
        .onDisappear { startingHue = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color range")
        .accessibilityValue(selection.rawValue)
        .accessibilityHint("Slide to choose a color. Hold, then slide up or down to adjust its hue.")
        .accessibilityIdentifier("colorDock.rainbow")
        .accessibilityAction(named: Text("Adjust hue"), onHueBegin)
        .accessibilityAdjustableAction { direction in
            let index = bands.firstIndex(of: selection) ?? 0
            selection = bands[min(bands.count - 1, max(0, index + (direction == .increment ? 1 : -1)))]
        }
    }

    private func select(at y: CGFloat, height: CGFloat) {
        let progress = min(1, max(0, (y - 11) / max(1, height - 22)))
        selection = bands[Int((progress * CGFloat(bands.count - 1)).rounded())]
    }
}

private struct RecipeBookmarksView: View {
    @EnvironmentObject private var colors: CameraColorStore
    @Environment(\.dismiss) private var dismiss
    @Binding var recipe: CameraColorRecipe
    let onCommit: () -> Void
    @State private var showSave = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var renaming = false
    @State private var renameIndex = 0
    @State private var renameText = ""
    private var matchingSlot: Int? { colors.slots.firstIndex { recipe.hasSameAdjustments(as: $0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    RecipeImagePreview(recipe: recipe, photo: photo).frame(height: 160)
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(photo == nil ? "Use your photo" : "Change preview photo", systemImage: "photo")
                    }.font(.subheadline)
                    Text("Image preview only: tint, saturation, contrast, sharpening and grain. Color Mix/HSL and clarity are not rendered yet. Recipes do not affect recorded video.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(colors.slots.enumerated()), id: \.offset) { index, saved in
                                Button {
                                    recipe = saved; colors.selectedSlot = index; onCommit()
                                } label: {
                                    VStack(spacing: 5) {
                                        RecipeImagePreview(recipe: saved, photo: photo, caption: false)
                                            .frame(width: 100, height: 64)
                                        Text(saved.name).font(.caption).lineLimit(2)
                                            .highPriorityGesture(TapGesture(count: 2).onEnded {
                                                renameIndex = index; renameText = saved.name; renaming = true
                                            })
                                            .accessibilityAction(named: Text("Rename")) {
                                                renameIndex = index; renameText = saved.name; renaming = true
                                            }
                                    }.padding(6)
                                        .background(.white.opacity(matchingSlot == index ? 0.12 : 0.03), in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("recipes.slot.\(index)")
                            }
                            Button {
                                let index = colors.addCustomColor()
                                recipe = colors.slots[index]; colors.selectedSlot = index; onCommit()
                            } label: {
                                Label("Add Color", systemImage: "plus").frame(width: 100, height: 100)
                            }.buttonStyle(.bordered)
                        }
                    }
                    Button { showSave = true } label: {
                        Text(matchingSlot == nil ? "Save these adjustments…" : "Save as…")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).tint(.yellow).foregroundStyle(.black)
                }.padding(16)
            }
            .background(InCamTheme.graphite)
            .navigationTitle("Custom Colors").navigationBarTitleDisplayMode(.inline)
            .alert("Rename Custom Color", isPresented: $renaming) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    let id = colors.slots[renameIndex].id
                    colors.rename(at: renameIndex, to: renameText)
                    if recipe.id == id { recipe.name = colors.slots[renameIndex].name; onCommit() }
                }
                Button("Cancel", role: .cancel) {}
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showSave) {
                SaveCameraColorView(recipe: recipe, initialSlot: matchingSlot, previewPhoto: photo) {
                    if let saved = colors.selectedRecipe { recipe = saved; onCommit() }
                }
            }
            .task(id: photoItem) {
                guard let photoItem, let data = try? await photoItem.loadTransferable(type: Data.self),
                      let source = UIImage(data: data), !Task.isCancelled else { return }
                photo = source.preparingThumbnail(of: CGSize(width: 960, height: 960)) ?? source
            }
        }.preferredColorScheme(.dark)
    }
}

private struct RecipeImagePreview: View {
    let recipe: CameraColorRecipe
    let photo: UIImage?
    var caption = true
    @State private var rendered: UIImage?

    var body: some View {
        Image(uiImage: rendered ?? photo ?? Self.demo)
            .resizable().scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                if caption {
                    Text(photo == nil ? "DEMO COLOR CHART · AFTER" : "YOUR PHOTO · AFTER")
                        .font(.system(size: 8, weight: .semibold))
                        .padding(5).background(.black.opacity(0.7), in: Capsule()).padding(6)
                }
            }
            .onAppear(perform: render)
            .onChange(of: recipe) { _, _ in render() }
            .onChange(of: photo) { _, _ in render() }
    }

    private func render() {
        guard let source = CIImage(image: photo ?? Self.demo) else { return }
        let output = RecipeRenderer.render(source, recipe: recipe)
        guard let cg = RecipeRenderer.context.createCGImage(output, from: output.extent) else { return }
        rendered = UIImage(cgImage: cg)
    }

    // A built-in reference chart; all displayed variants use the actual still-image renderer.
    private static let demo: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360)).image { renderer in
        let context = renderer.cgContext
        let colors: [UIColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .cyan, .systemBlue, .systemPurple, .magenta]
        for (index, color) in colors.enumerated() {
            color.setFill()
            context.fill(CGRect(x: index * 80, y: 0, width: 80, height: 220))
            UIColor(white: CGFloat(index) / 7, alpha: 1).setFill()
            context.fill(CGRect(x: index * 80, y: 220, width: 80, height: 140))
        }
        UIColor(red: 0.73, green: 0.48, blue: 0.32, alpha: 1).setFill()
        context.fillEllipse(in: CGRect(x: 245, y: 110, width: 150, height: 150))
    }
}

private struct CompactColorSlider: View {
    @Binding var value: Double
    let tint: Color
    let onCommit: () -> Void
    @State private var horizontalDrag: Bool?
    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - 16)
            let progress = CGFloat((value + 1) / 2)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: 2)
                Capsule().fill(tint).frame(width: 8 + progress * travel, height: 2)
                Circle().fill(InCamTheme.ivory).frame(width: 14, height: 14).offset(x: progress * travel + 1)
            }.frame(height: 32).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onChanged { drag in
                    if horizontalDrag == nil { horizontalDrag = abs(drag.translation.width) >= abs(drag.translation.height) }
                    guard horizontalDrag == true else { return }
                    let raw = Double((drag.location.x - 8) / travel) * 2 - 1
                    value = min(1, max(-1, (raw * 100).rounded() / 100))
                }.onEnded { _ in if horizontalDrag == true { onCommit() }; horizontalDrag = nil })
        }.frame(height: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(String(format: "%+.0f", value * 100))
        .accessibilityAdjustableAction { direction in
            value = min(1, max(-1, value + (direction == .increment ? 0.01 : -0.01))); onCommit()
        }
    }
}
