import AVFoundation
import CoreImage
import MetalKit
import SwiftUI
import UIKit

/// The camera controller produces frames; this narrow interface lets the
/// preview view present the newest one without coupling capture code to UIKit.
protocol SelectiveColorPreviewSink: AnyObject {
    func setSelectiveColorPreviewActive(_ active: Bool)
    func setSelectiveColorPreviewFrameRate(_ framesPerSecond: Int)
    func submitSelectiveColorFrame(_ pixelBuffer: CVPixelBuffer, recipe: CameraColorRecipe)
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraController
    /// Focus needs an intentional one-second hold so ordinary taps remain
    /// available for AE lock and visible SwiftUI controls such as CC slots.
    var onFocusHold: ((CGPoint, CGPoint) -> Void)? = nil
    /// A single tap locks AE at the selected point. The target itself owns the
    /// following hold-and-drag exposure adjustment gesture.
    var onExposureTap: ((CGPoint) -> Void)? = nil
    /// Pinch changes to the adjacent physical iPhone lens. It does not invoke
    /// digital zoom; the right thumb pad remains the zoom-only control.
    var onLensPinch: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.setSelectivePreviewSink(view.selectiveColorPreview)
        view.onFocusHold = onFocusHold
        view.onExposureTap = onExposureTap
        view.onLensPinch = onLensPinch
        let exposure = UITapGestureRecognizer(target: view, action: #selector(PreviewHostView.exposureTapped(_:)))
        exposure.delegate = view
        exposure.cancelsTouchesInView = false
        let focus = UILongPressGestureRecognizer(target: view, action: #selector(PreviewHostView.focusHeld(_:)))
        focus.minimumPressDuration = 1.0
        focus.delegate = view
        focus.cancelsTouchesInView = false
        // A held focus must win over a normal tap, preventing an accidental
        // AE lock immediately before the intended focus request.
        exposure.require(toFail: focus)
        view.addGestureRecognizer(exposure)
        view.addGestureRecognizer(focus)
        let pinch = UIPinchGestureRecognizer(target: view, action: #selector(PreviewHostView.zoomPinched(_:)))
        pinch.delegate = view
        pinch.cancelsTouchesInView = false
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.previewLayer.session = camera.session
        camera.setSelectivePreviewSink(uiView.selectiveColorPreview)
        uiView.onFocusHold = onFocusHold
        uiView.onExposureTap = onExposureTap
        uiView.onLensPinch = onLensPinch
        uiView.updateOrientation()
    }

    static func dismantleUIView(_ uiView: PreviewHostView, coordinator: ()) {
        uiView.detachSelectiveColorPreview()
    }
}

final class PreviewHostView: UIView, UIGestureRecognizerDelegate {
    var onFocusHold: ((CGPoint, CGPoint) -> Void)?
    var onExposureTap: ((CGPoint) -> Void)?
    var onLensPinch: ((Bool) -> Void)?
    /// The compact WB/Tint/Shutter/ISO rail sits over the trailing edge of the
    /// live image. Those controls must remain transparent to the preview's
    /// focus and AE recognizers: touching a readout opens its dial, never
    /// moves the focus or AE target behind it.
    private let readoutRailExclusionWidth: CGFloat = 92
    private var appliedOrientation: UIInterfaceOrientation = .unknown
    private var appliedFrontCameraState: Bool?
    private var hasTriggeredLensPinch = false
    let selectiveColorPreview = MetalColorPreviewView()
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        selectiveColorPreview.isUserInteractionEnabled = false
        addSubview(selectiveColorPreview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func exposureTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, bounds.width > 0, bounds.height > 0 else { return }
        let location = gesture.location(in: self)
        onExposureTap?(CGPoint(x: location.x / bounds.width, y: location.y / bounds.height))
    }

    @objc func focusHeld(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, bounds.width > 0, bounds.height > 0 else { return }
        let location = gesture.location(in: self)
        let displayPoint = CGPoint(x: location.x / bounds.width, y: location.y / bounds.height)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        onFocusHold?(devicePoint, displayPoint)
    }

    @objc func zoomPinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            hasTriggeredLensPinch = false
        case .changed:
            guard !hasTriggeredLensPinch else { return }
            // At either physical-lens end the controller does nothing instead
            // of silently falling back to digital zoom.
            if gesture.scale >= 1.16 {
                hasTriggeredLensPinch = true
                onLensPinch?(true)
            } else if gesture.scale <= 0.84 {
                hasTriggeredLensPinch = true
                onLensPinch?(false)
            }
        case .ended, .cancelled, .failed:
            hasTriggeredLensPinch = false
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Pinching must never steal a focus or AE double-tap from the preview.
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer else { return true }
        let point = touch.location(in: self)
        // The rail's actual buttons remain responsible for their own taps;
        // this simply prevents the underlying preview recognizers from seeing
        // the same touch.
        return point.x < bounds.width - readoutRailExclusionWidth
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        selectiveColorPreview.frame = bounds
        updateOrientation()
    }
    func detachSelectiveColorPreview() { selectiveColorPreview.setSelectiveColorPreviewActive(false) }
    override func didMoveToWindow() { super.didMoveToWindow(); updateOrientation() }
    func updateOrientation() {
        guard let orientation = window?.windowScene?.interfaceOrientation,
              let connection = previewLayer.connection else { return }
        let isFrontCamera = previewLayer.session?.inputs.contains {
            ($0 as? AVCaptureDeviceInput)?.device.position == .front
        } ?? false
        guard orientation != appliedOrientation || isFrontCamera != appliedFrontCameraState else { return }
        appliedOrientation = orientation
        appliedFrontCameraState = isFrontCamera
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            // Use the capture connection's horizontal-mirror feature rather
            // than applying an affine transform after rotation. A transformed
            // layer was the source of the apparent vertical/upside-down flip.
            connection.isVideoMirrored = isFrontCamera
        }
        previewLayer.setAffineTransform(.identity)
        // The Color Mix stream uses AVFoundation connection mirroring too.
        // Keep its view untransformed: a second screen-space flip after
        // rotation was the cause of the inverted front-camera preview.
        selectiveColorPreview.transform = .identity
        if connection.isVideoRotationAngleSupported(orientation.cameraRotationAngle) {
            connection.videoRotationAngle = orientation.cameraRotationAngle
        }
    }

}

/// A direct CI-on-Metal presentation surface. It receives the newest camera
/// texture, not a UIImage, and presents at the display cadence. Replacing the
/// latest input instead of queueing frames is what keeps Color Mix responsive.
final class MetalColorPreviewView: UIView, SelectiveColorPreviewSink, MTKViewDelegate {
    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let stateLock = NSLock()
    private var active = false
    private var latestFrame: CIImage?
    private var latestRecipe = CameraColorRecipe(name: "Custom Color")

    override init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("InCam requires a Metal-capable iPhone for Color Mix preview.")
        }
        metalView = MTKView(frame: .zero, device: device)
        commandQueue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init(frame: frame)

        // The host remains transparent until the Metal drawable receives its
        // first color-mixed frame, so the native preview never flashes black.
        isOpaque = false
        clipsToBounds = true
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.preferredFramesPerSecond = 30
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        metalView.delegate = self
        metalView.isUserInteractionEnabled = false
        metalView.isHidden = true
        addSubview(metalView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
    }

    func setSelectiveColorPreviewActive(_ active: Bool) {
        stateLock.lock()
        let changed = self.active != active
        self.active = active
        if !active { latestFrame = nil }
        stateLock.unlock()
        guard changed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metalView.isHidden = !active
            self.metalView.isPaused = !active
        }
    }

    /// Heat recovery reduces only the optional graded preview cadence. The
    /// selected recording resolution, frame rate, lens and exposure remain
    /// untouched, and the normal cadence returns after pressure subsides.
    func setSelectiveColorPreviewFrameRate(_ framesPerSecond: Int) {
        let rate = max(15, min(30, framesPerSecond))
        DispatchQueue.main.async { [weak self] in
            self?.metalView.preferredFramesPerSecond = rate
        }
    }

    func submitSelectiveColorFrame(_ pixelBuffer: CVPixelBuffer, recipe: CameraColorRecipe) {
        // CIImage wraps the camera's IOSurface instead of copying pixels. The
        // display callback takes only the most recent frame, so late camera
        // frames never build a visible delay behind the subject.
        stateLock.lock()
        guard active else { stateLock.unlock(); return }
        latestFrame = CIImage(cvPixelBuffer: pixelBuffer)
        latestRecipe = recipe
        stateLock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        stateLock.lock()
        let active = active
        let frame = latestFrame
        let recipe = latestRecipe
        stateLock.unlock()
        guard active, let frame, let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let rendered = RecipeRenderer.render(frame, recipe: recipe)
        let destination = CGRect(origin: .zero, size: view.drawableSize)
        let fitted = aspectFill(rendered, in: destination)
        context.render(fitted, to: drawable.texture, commandBuffer: commandBuffer,
                       bounds: destination, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func aspectFill(_ image: CIImage, in destination: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 0, source.height > 0 else { return image }
        let scale = max(destination.width / source.width, destination.height / source.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(
            translationX: destination.midX - scaled.extent.midX,
            y: destination.midY - scaled.extent.midY
        ))
    }
}

/// Keeps the exposure ruler next to its target, inside the camera image.
enum ExposureDialLayout {
    static func center(target: CGPoint, viewport: CGSize, dockHeight: CGFloat = 64) -> CGPoint {
        let halfWidth: CGFloat = 22
        let gap: CGFloat = 6
        let targetX = min(viewport.width - 24, max(24, target.x * viewport.width))
        let targetY = min(viewport.height - 24, max(24, target.y * viewport.height))
        let right = targetX + 22 + gap + halfWidth
        let left = targetX - 22 - gap - halfWidth
        let x = right + halfWidth <= viewport.width - 8 ? right : left
        return CGPoint(x: min(max(halfWidth + 8, x), max(halfWidth + 8, viewport.width - halfWidth - 8)),
                       y: targetY)
    }
}
