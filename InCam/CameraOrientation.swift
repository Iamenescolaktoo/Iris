import SwiftUI
import UIKit

enum CameraOrientationLock: String, CaseIterable, Identifiable {
    case unlocked = "Unlocked"
    case portrait = "Portrait"
    case landscapeLeft = "Landscape Left"
    case landscapeRight = "Landscape Right"
    var id: String { rawValue }

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .unlocked: return .landscape
        case .portrait: return .landscapeRight // Migrate legacy portrait preferences.
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        }
    }
}

@MainActor
final class CameraOrientation: ObservableObject {
    static let shared = CameraOrientation()
    @Published private(set) var selection: CameraOrientationLock
    @Published private(set) var interfaceOrientation: UIInterfaceOrientation = .landscapeRight
    @Published private(set) var windowSafeAreaInsets: UIEdgeInsets = .zero
    @Published var errorMessage: String?
    private weak var scene: UIWindowScene?
    private var recordingMask: UIInterfaceOrientationMask?

    private init() {
        selection = CameraOrientationLock(rawValue: UserDefaults.standard.string(forKey: "incam.orientationLock") ?? "") ?? .landscapeRight
        if selection == .portrait { selection = .landscapeRight }
    }

    var supportedOrientations: UIInterfaceOrientationMask { recordingMask ?? selection.mask }
    var rotationAngle: CGFloat { interfaceOrientation.cameraRotationAngle }

    func attach(_ scene: UIWindowScene) {
        let changed = self.scene !== scene
        self.scene = scene
        updateFromScene()
        if changed { requestOrientation() }
    }

    func select(_ value: CameraOrientationLock) {
        guard recordingMask == nil else { return }
        selection = value == .portrait ? .landscapeRight : value
        UserDefaults.standard.set(selection.rawValue, forKey: "incam.orientationLock")
        requestOrientation()
    }

    // Even in Unlocked mode, don't rotate the UI/capture partway through a clip.
    func setRecording(_ recording: Bool) {
        recordingMask = recording ? interfaceOrientation.orientationMask : nil
        requestOrientation()
    }

    func updateFromScene() {
        if let insets = scene?.windows.first(where: \.isKeyWindow)?.safeAreaInsets,
           insets != windowSafeAreaInsets { windowSafeAreaInsets = insets }
        guard let orientation = scene?.interfaceOrientation, orientation != .unknown,
              orientation != interfaceOrientation else { return }
        interfaceOrientation = orientation
    }

    private func requestOrientation() {
        guard let scene else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: supportedOrientations)) { [weak self] error in
            Task { @MainActor in self?.errorMessage = error.localizedDescription }
        }
    }
}

extension UIInterfaceOrientation {
    /// AVCapture rotation is clockwise from the sensor's landscape-right basis.
    var cameraRotationAngle: CGFloat {
        switch self {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        default: return 0
        }
    }

    var orientationMask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        default: return .landscapeRight
        }
    }
}

final class InCamAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        CameraOrientation.shared.supportedOrientations
    }
}

/// Reads the actual window orientation, not the phone's transient motion data.
struct CameraOrientationReader: UIViewRepresentable {
    func makeUIView(context: Context) -> OrientationHostView { OrientationHostView() }
    func updateUIView(_ uiView: OrientationHostView, context: Context) { uiView.report() }

    final class OrientationHostView: UIView {
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        func report() {
            guard let scene = window?.windowScene else { return }
            DispatchQueue.main.async { CameraOrientation.shared.attach(scene) }
        }
    }
}

struct OrientationLockMenu: View {
    @ObservedObject private var orientation = CameraOrientation.shared
    @EnvironmentObject private var camera: CameraController
    @State private var showChoices = false

    var body: some View {
        Button { showChoices.toggle() } label: {
            Image(systemName: orientation.selection == .unlocked ? "lock.open.rotation" : "lock.rotation")
                .foregroundStyle(orientation.selection == .unlocked ? InCamTheme.ivory : .yellow)
                .frame(width: 38, height: 36)
                .glass(in: Capsule())
        }
        .disabled(camera.isRecording)
        .accessibilityLabel("Orientation lock")
        .accessibilityValue(orientation.selection.rawValue)
        .accessibilityIdentifier("camera.orientationLock")
        .accessibilityHint("Open orientation choices below")
        .overlay(alignment: .topTrailing) {
            if showChoices {
                VStack(spacing: 4) {
                    ForEach(CameraOrientationLock.allCases.filter { $0 != .portrait }) { option in
                        Button {
                            showChoices = false
                            orientation.select(option)
                        } label: {
                            HStack {
                                Text(option.rawValue)
                                Spacer()
                                if orientation.selection == option { Image(systemName: "checkmark") }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 44)
                            .foregroundStyle(orientation.selection == option ? .yellow : InCamTheme.ivory)
                            .glass(in: RoundedRectangle(cornerRadius: 12), emphasized: orientation.selection == option)
                        }
                        .accessibilityIdentifier("orientation.option.\(option.rawValue)")
                        .accessibilityAddTraits(orientation.selection == option ? .isSelected : [])
                    }
                }
                .frame(width: 168)
                .buttonStyle(.plain)
                .offset(y: 46)
            }
        }
        .zIndex(showChoices ? 10 : 0)
        .onChange(of: camera.isRecording) { _, recording in if recording { showChoices = false } }
        .onChange(of: orientation.interfaceOrientation) { _, _ in showChoices = false }
    }
}
