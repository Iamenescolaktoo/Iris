import AVFoundation
import CoreImage
import MetalKit
import MetalPetal
import SwiftUI
import UIKit

// FILE GUIDE: UIKit/Metal preview bridge. It presents AVCapture frames and
// forwards tap, hold and pinch gestures to CameraScreen; it does not configure
// the camera session itself.

/// The camera controller produces frames; this narrow interface lets the
/// preview view present the newest one without coupling capture code to UIKit.
protocol SelectiveColorPreviewSink: AnyObject {
    func setSelectiveColorPreviewActive(_ active: Bool)
    func setSelectiveColorPreviewFrameRate(_ framesPerSecond: Int)
    func submitSelectiveColorFrame(_ pixelBuffer: CVPixelBuffer, recipe: CameraColorRecipe)
    func setFocusPeakingPreviewActive(_ active: Bool)
    func submitFocusPeakingFrame(_ pixelBuffer: CVPixelBuffer)
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var camera: CameraController
    /// Focus needs an intentional one-second hold so ordinary taps remain
    /// available for AE lock and visible SwiftUI controls such as CC slots.
    var onFocusHold: ((CGPoint, CGPoint) -> Void)? = nil
    /// A single tap locks AE at the selected point. The target itself owns the
    /// following hold-and-drag exposure adjustment gesture.
    /// Device-space and display-space coordinates are both required: the
    /// capture session meters from device space while SwiftUI draws the
    /// visible AE target in display space.
    var onExposureTap: ((CGPoint, CGPoint) -> Void)? = nil
    /// Pinch controls the current lens's optical/digital zoom range. The
    /// camera screen temporarily reveals its existing zoom ruler at Record.
    var onZoomPinch: ((CGFloat, Bool) -> Void)? = nil
    /// A preview-layer readiness event used only for startup instrumentation.
    /// It is a native display signal and requires no analysis video output.
    var onPreviewFrameReady: (() -> Void)? = nil

    // Creates the UIKit host, connects it to the shared AVCapture session and installs gestures once.
    func makeUIView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = camera.session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onPreviewFrameReady = { [weak camera] in
            camera?.previewLayerDidBeginDisplayingFrames()
        }
        let needsRenderer = camera.selectiveColorPreviewActive || !camera.focusAuto
        camera.setSelectivePreviewSink(view.selectiveColorPreview(whenNeeded: needsRenderer))
        view.onFocusHold = onFocusHold
        view.onExposureTap = onExposureTap
        view.onZoomPinch = onZoomPinch
        view.frontPreviewMirrored = camera.frontPreviewMirrored
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

    // Synchronizes preview orientation, front-camera transforms and optional color-preview state from SwiftUI.
    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        uiView.previewLayer.session = camera.session
        uiView.onPreviewFrameReady = { [weak camera] in
            camera?.previewLayerDidBeginDisplayingFrames()
        }
        let needsRenderer = camera.selectiveColorPreviewActive || !camera.focusAuto
        camera.setSelectivePreviewSink(uiView.selectiveColorPreview(whenNeeded: needsRenderer))
        uiView.onFocusHold = onFocusHold
        uiView.onExposureTap = onExposureTap
        uiView.onZoomPinch = onZoomPinch
        uiView.frontPreviewMirrored = camera.frontPreviewMirrored
        uiView.updateOrientation()
    }

    // Detaches the optional renderer when SwiftUI removes the preview host from its hierarchy.
    static func dismantleUIView(_ uiView: PreviewHostView, coordinator: ()) {
        uiView.detachSelectiveColorPreview()
    }
}

final class PreviewHostView: UIView, UIGestureRecognizerDelegate {
    var onFocusHold: ((CGPoint, CGPoint) -> Void)?
    var onExposureTap: ((CGPoint, CGPoint) -> Void)?
    var onZoomPinch: ((CGFloat, Bool) -> Void)?
    var onPreviewFrameReady: (() -> Void)?
    var frontPreviewMirrored = false
    /// The compact WB/Tint/Shutter/ISO rail sits over the trailing edge of the
    /// live image. Those controls must remain transparent to the preview's
    /// focus and AE recognizers: touching a readout opens its dial, never
    /// moves the focus or AE target behind it.
    private let readoutRailExclusionWidth: CGFloat = 92
    private var appliedOrientation: UIInterfaceOrientation = .unknown
    private var appliedFrontCameraState: Bool?
    private var appliedFrontPreviewMirroredState: Bool?
    /// The CI/Metal overlay is intentionally lazy. In ordinary AF shooting the
    /// native AVCaptureVideoPreviewLayer is the only preview surface; creating
    /// a MTLDevice, CIContext and Metal views at view construction made every
    /// camera open pay for tools that were not active.
    private var selectiveColorPreviewView: MetalColorPreviewView?
    private var previewingObservation: NSKeyValueObservation?
    private var wasPreviewing = false
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        previewingObservation = previewLayer.observe(\.isPreviewing, options: [.initial, .new]) { [weak self] layer, _ in
            guard let self else { return }
            let isPreviewing = layer.isPreviewing
            guard isPreviewing, !self.wasPreviewing else {
                self.wasPreviewing = isPreviewing
                return
            }
            self.wasPreviewing = true
            DispatchQueue.main.async { [weak self] in
                self?.onPreviewFrameReady?()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func exposureTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, bounds.width > 0, bounds.height > 0 else { return }
        let location = gesture.location(in: self)
        let displayPoint = CGPoint(x: location.x / bounds.width, y: location.y / bounds.height)
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: location)
        onExposureTap?(devicePoint, displayPoint)
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
            onZoomPinch?(1, false)
        case .changed:
            onZoomPinch?(gesture.scale, false)
        case .ended, .cancelled, .failed:
            onZoomPinch?(gesture.scale, true)
        default:
            break
        }
    }

    // Allows long-press focus and pinch zoom recognizers to coexist on the same live preview.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Pinching must never steal a focus or AE double-tap from the preview.
        gestureRecognizer is UIPinchGestureRecognizer || otherGestureRecognizer is UIPinchGestureRecognizer
    }

    // Rejects gestures outside the active preview surface so controls retain their own touches.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer is UITapGestureRecognizer || gestureRecognizer is UILongPressGestureRecognizer else { return true }
        let point = touch.location(in: self)
        // The rail's actual buttons remain responsible for their own taps;
        // this simply prevents the underlying preview recognizers from seeing
        // the same touch.
        return point.x < bounds.width - readoutRailExclusionWidth
    }

    // Resizes the preview layer and selective renderer whenever UIKit changes the host bounds.
    override func layoutSubviews() {
        super.layoutSubviews()
        selectiveColorPreviewView?.frame = bounds
        updateOrientation()
    }
    // Stops Metal preview processing immediately when the overlay is removed.
    func detachSelectiveColorPreview() { selectiveColorPreviewView?.setSelectiveColorPreviewActive(false) }

    /// Returns the lazily-created renderer only while Color Mix or Manual Focus
    /// needs it. Leaving it absent in normal AF mode avoids Metal/Core Image
    /// setup during the first viewfinder frame.
    func selectiveColorPreview(whenNeeded needed: Bool) -> MetalColorPreviewView? {
        guard needed else {
            selectiveColorPreviewView?.setSelectiveColorPreviewActive(false)
            selectiveColorPreviewView?.setFocusPeakingPreviewActive(false)
            return nil
        }
        if let selectiveColorPreviewView { return selectiveColorPreviewView }
        let preview = MetalColorPreviewView()
        preview.isUserInteractionEnabled = false
        preview.frame = bounds
        addSubview(preview)
        selectiveColorPreviewView = preview
        updateOrientation()
        return preview
    }
    // Refreshes preview orientation after UIKit attaches this host to a window.
    override func didMoveToWindow() { super.didMoveToWindow(); updateOrientation() }
    // Maps the current window interface orientation into AVCapture preview orientation.
    func updateOrientation() {
        guard let orientation = window?.windowScene?.interfaceOrientation,
              let connection = previewLayer.connection else { return }
        let isFrontCamera = previewLayer.session?.inputs.contains {
            ($0 as? AVCaptureDeviceInput)?.device.position == .front
        } ?? false
        guard orientation != appliedOrientation ||
                isFrontCamera != appliedFrontCameraState ||
                frontPreviewMirrored != appliedFrontPreviewMirroredState else { return }
        appliedOrientation = orientation
        appliedFrontCameraState = isFrontCamera
        appliedFrontPreviewMirroredState = frontPreviewMirrored
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            // Saved camera media stays unmirrored. The optional mirror below
            // is presentation-only, so it changes left/right tracking without
            // changing upright orientation or captured output.
            connection.isVideoMirrored = false
        }
        let uprightFrontTransform = isFrontCamera
            ? CGAffineTransform(scaleX: -1, y: -1)
            : .identity
        // This is horizontal in display coordinates after the upright front
        // transform, even though the combined source-space matrix is (1, -1).
        let presentationTransform = isFrontCamera && frontPreviewMirrored
            ? uprightFrontTransform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
            : uprightFrontTransform
        previewLayer.setAffineTransform(presentationTransform)
        selectiveColorPreviewView?.transform = presentationTransform
        if connection.isVideoRotationAngleSupported(orientation.cameraRotationAngle) {
            connection.videoRotationAngle = orientation.cameraRotationAngle
        }
    }

}

/// A direct CI-on-Metal presentation surface. It receives the newest camera
/// texture, not a UIImage, and presents at the display cadence. Replacing the
/// latest input instead of queueing frames keeps Color Mix and focus peaking
/// responsive without building a delayed preview backlog.
final class MetalColorPreviewView: UIView, SelectiveColorPreviewSink, MTKViewDelegate {
    private let metalView: MTKView
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    /// Raster's MetalPetal-compatible image view owns a second, transparent
    /// Metal drawable. It draws the *mask only* over AVCapture's native
    /// preview instead of redrawing every camera pixel through Core Image.
    private let focusPeakingView: MTIThreadSafeImageView
    private var focusPeakingContext: MTIContext?
    private let focusPeakingKernel: MTIRenderPipelineKernel
    private let stateLock = NSLock()
    private var active = false
    private var focusPeakingActive = false
    private var latestFrame: CIImage?
    private var latestRecipe = CameraColorRecipe(name: "Custom Color")
    private var drawScheduled = false
    /// The Metal drawable can accept command buffers faster than a thermally
    /// constrained GPU can complete them. Keep at most one peaking render in
    /// flight and replace this slot with the newest camera frame instead of
    /// building a command-buffer queue behind the live preview.
    private var peakingRenderInFlight = false
    private var pendingPeakingPixelBuffer: CVPixelBuffer?
    private var lastPeakingSubmissionTime: CFTimeInterval = 0
    private let peakingMinimumInterval: CFTimeInterval = 1.0 / 24.0

    override init(frame: CGRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("InCam requires a Metal-capable iPhone for Color Mix preview.")
        }
        metalView = MTKView(frame: .zero, device: device)
        commandQueue = queue
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        focusPeakingView = MTIThreadSafeImageView(frame: .zero)
        focusPeakingKernel = MTIRenderPipelineKernel(
            vertexFunctionDescriptor: .passthroughVertex,
            fragmentFunctionDescriptor: MTIFunctionDescriptor(name: "focusPeakingOverlay", in: .main)
        )
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

        // The peaking image contains transparent pixels everywhere except
        // resolved high-frequency edges, preserving AVCapture's efficient
        // native preview as the only full-frame image presentation.
        focusPeakingView.colorPixelFormat = .bgra8Unorm
        focusPeakingView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        focusPeakingView.resizingMode = .aspectFill
        focusPeakingView.isOpaque = false
        focusPeakingView.isUserInteractionEnabled = false
        focusPeakingView.isHidden = true
        addSubview(focusPeakingView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Keeps the Metal drawable aligned to the UIKit overlay bounds.
    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        focusPeakingView.frame = bounds
    }

    // Enables/disables the optional Color Mix renderer and releases its frame when disabled.
    func setSelectiveColorPreviewActive(_ active: Bool) {
        stateLock.lock()
        self.active = active
        if !active { latestFrame = nil }
        let focusPeakingActive = focusPeakingActive
        stateLock.unlock()
        updateColorPresentation(active: active && !focusPeakingActive, frameRate: active ? 30 : nil)
    }

    /// Heat recovery reduces only the optional graded preview cadence. The
    /// selected recording resolution, frame rate, lens and exposure remain
    /// untouched, and the normal cadence returns after pressure subsides.
    // Sets a capped processing cadence for the optional selective-color preview.
    func setSelectiveColorPreviewFrameRate(_ framesPerSecond: Int) {
        let rate = max(15, min(30, framesPerSecond))
        stateLock.lock()
        let focusPeakingActive = focusPeakingActive
        stateLock.unlock()
        guard !focusPeakingActive else { return }
        DispatchQueue.main.async { [weak self] in
            self?.metalView.preferredFramesPerSecond = rate
        }
    }

    // Accepts only the newest eligible camera frame, intentionally dropping stale preview work.
    func submitSelectiveColorFrame(_ pixelBuffer: CVPixelBuffer, recipe: CameraColorRecipe) {
        // CIImage wraps the camera's IOSurface instead of copying pixels. The
        // display callback takes only the most recent frame, so late camera
        // frames never build a visible delay behind the subject.
        stateLock.lock()
        guard active else { stateLock.unlock(); return }
        latestFrame = CIImage(cvPixelBuffer: pixelBuffer)
        latestRecipe = recipe
        stateLock.unlock()
        requestLatestFrameDraw()
    }

    /// Focus peaking presents only a transparent edge mask through Raster's
    /// MetalPetal-compatible render graph. The camera image remains in the
    /// AVCapture preview layer, avoiding a full-frame replacement render.
    func setFocusPeakingPreviewActive(_ active: Bool) {
        stateLock.lock()
        focusPeakingActive = active
        if !active { pendingPeakingPixelBuffer = nil }
        let colorPreviewActive = self.active
        stateLock.unlock()
        // Color Mix stays available, but focus peaking takes visual priority
        // in MF because it must remain a transparent overlay on the native
        // preview rather than a second full-frame compositing pass.
        updateColorPresentation(active: colorPreviewActive && !active,
                                frameRate: colorPreviewActive ? 30 : nil)
        DispatchQueue.main.async { [weak self] in
            self?.focusPeakingView.isHidden = !active
        }
        if !active {
            focusPeakingView.setImage(nil, renderCompletion: nil)
        }
    }

    /// Raster wraps the capture IOSurface directly. The GPU computes a Sobel
    /// contrast mask and sends only that red overlay to its transparent view;
    /// no UIImage, CPU bitmap, or full-frame camera re-composite is involved.
    func submitFocusPeakingFrame(_ pixelBuffer: CVPixelBuffer) {
        stateLock.lock()
        guard focusPeakingActive else { stateLock.unlock(); return }
        if peakingRenderInFlight {
            // Retaining one CVPixelBuffer is deliberate: it is the latest
            // proxy frame, not an ever-growing queue of old camera images.
            pendingPeakingPixelBuffer = pixelBuffer
            stateLock.unlock()
            return
        }
        let now = CACurrentMediaTime()
        guard now - lastPeakingSubmissionTime >= peakingMinimumInterval else {
            stateLock.unlock()
            return
        }
        peakingRenderInFlight = true
        lastPeakingSubmissionTime = now
        stateLock.unlock()

        renderFocusPeaking(pixelBuffer)
    }

    private func renderFocusPeaking(_ pixelBuffer: CVPixelBuffer) {
        // AF launch remains native-preview-only. Raster's context is created
        // only after MF first needs it, on the dedicated capture callback.
        guard ensureFocusPeakingContext() else {
            finishFocusPeakingRender()
            return
        }
        let source = MTIImage(cvPixelBuffer: pixelBuffer, alphaType: .alphaIsOne)
        let overlay = focusPeakingKernel.apply(
            to: [source],
            parameters: [:],
            outputDimensions: source.dimensions,
            outputPixelFormat: .bgra8Unorm
        )
        // MTIThreadSafeImageView renders on this capture callback rather than
        // hopping through the main queue. AVCapture drops late input frames,
        // so the viewfinder stays current under load instead of lagging.
        focusPeakingView.setImage(overlay) { [weak self] _ in
            self?.finishFocusPeakingRender()
        }
    }

    /// Finishes the GPU task, then immediately submits the single newest
    /// replacement frame if one arrived. This is latest-wins scheduling:
    /// the overlay may skip frames but can never become a delayed sequence.
    private func finishFocusPeakingRender() {
        stateLock.lock()
        guard focusPeakingActive, let newest = pendingPeakingPixelBuffer else {
            peakingRenderInFlight = false
            pendingPeakingPixelBuffer = nil
            stateLock.unlock()
            return
        }
        pendingPeakingPixelBuffer = nil
        // Keep the gate closed while the replacement is submitted.
        stateLock.unlock()
        renderFocusPeaking(newest)
    }

    /// Creates the retained Raster context only when Manual Focus is used.
    /// The video-data delegate is serial, so this has no setup race and keeps
    /// normal AF camera opening free of GPU graph initialization work.
    private func ensureFocusPeakingContext() -> Bool {
        if focusPeakingContext != nil { return true }
        guard let device = metalView.device else { return false }
        do {
            let context = try MTIContext(device: device)
            focusPeakingContext = context
            focusPeakingView.context = context
            return true
        } catch {
            return false
        }
    }

    // MetalKit callback; no cached geometry is needed because dra=w reads the current drawable size.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // Renders the newest queued frame through the active GPU processing path.
    func draw(in view: MTKView) {
        stateLock.lock()
        drawScheduled = false
        let colorPreviewActive = active
        let frame = latestFrame
        let recipe = latestRecipe
        stateLock.unlock()
        guard colorPreviewActive, let frame, let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let rendered = RecipeRenderer.render(frame, recipe: recipe)
        let destination = CGRect(origin: .zero, size: view.drawableSize)
        let fitted = aspectFill(rendered, in: destination)
        context.render(fitted, to: drawable.texture, commandBuffer: commandBuffer,
                       bounds: destination, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Makes visibility and cadence changes on UIKit's main thread. A missing
    /// frame leaves the native preview visible underneath, avoiding a black
    /// flash while a new Metal mode acquires its first camera frame.
    private func updateColorPresentation(active: Bool, frameRate: Int?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metalView.isHidden = !active
            // Frames explicitly request a draw below. Avoid an idle 60 Hz
            // re-render of the same CI graph when the camera is delivering a
            // slower format such as 24 or 30 fps.
            self.metalView.isPaused = true
            if let frameRate { self.metalView.preferredFramesPerSecond = frameRate }
        }
    }

    /// Coalesces capture callbacks into one main-thread Metal draw. A frame
    /// arriving while a draw is already scheduled simply replaces the source,
    /// which prevents a backlog and keeps the displayed frame current.
    private func requestLatestFrameDraw() {
        stateLock.lock()
        guard !drawScheduled else { stateLock.unlock(); return }
        drawScheduled = true
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.metalView.draw()
        }
    }

    // Scales and centers a CIImage to fill the drawable without changing its source aspect ratio.
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
    // Calculates a target-centered position that remains visible above the bottom dock.
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
