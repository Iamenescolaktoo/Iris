import AVFoundation
import CoreImage
import CoreMotion
import os
import Photos
import SwiftUI

// FILE GUIDE: The sole AVFoundation owner. It serializes camera, microphone,
// lens, focus, exposure and recording work on a private queue so hardware
// changes cannot collide with SwiftUI drawing. See APP_WORKFLOW.md for timing.

final class CameraController: NSObject, ObservableObject {
    private static let savedMediaKey = "incam.private-media.v1"
    let session = AVCaptureSession()

    @Published private(set) var authorization: AVAuthorizationStatus = .notDetermined
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var isCapturingPhoto = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var capabilities = CameraCapabilities()
    @Published var mode: CaptureMode = .video
    @Published var zoom: CGFloat = 1
    @Published private(set) var zoomCap: CGFloat = 5
    @Published var iso: Float = 100
    @Published var exposureSeconds: Double = CameraExposureDefaults.defaultShutterSeconds
    /// The last deliberate shutter-speed choice. Auto exposure is free to
    /// meter a scene at 1/3 or another value, but the manual dial must reopen
    /// at the person's own previous setting instead of inheriting that meter.
    @Published private(set) var lastManualExposureSeconds: Double = CameraExposureDefaults.defaultShutterSeconds
    /// The current lens f-number. Most iPhone lenses expose this as fixed
    /// hardware, so it is displayed truthfully rather than simulated.
    @Published private(set) var aperture: Float = 0
    @Published var frameRate: Int = 24
    /// The paused-4K build starts at 1080p. Hardware still reports its supported
    /// formats, but the 4K route is withheld through AppFeatureAvailability.
    @Published private(set) var videoResolution: VideoResolution = .p1080
    @Published private(set) var availableVideoResolutions: [VideoResolution] = []
    @Published private(set) var videoCodec: VideoCodec = .hevc
    @Published private(set) var availableVideoCodecs: [VideoCodec] = []
    /// Chooses how every shutter control is presented. The underlying duration
    /// remains the same; only its Speed or Angle representation changes.
    @Published var shutterAngleMode = false
    /// A shutter angle is frame-relative. Storing it independently lets 180°
    /// or 360° remain selected when a person changes the recording frame rate.
    @Published private(set) var shutterAngleDegrees: Double = 180
    @Published private(set) var rawPhotoSupported = false
    @Published private(set) var videoHDRSupported = false
    @Published private(set) var videoHDREnabled = false
    @Published private(set) var videoStabilization: VideoStabilization = .auto
    @Published private(set) var availableVideoStabilizations: [VideoStabilization] = [.off]
    /// This is an InCam recipe-workflow mode, not an assertion that the device
    /// is recording Apple Log. It keeps incompatible global color controls off.
    @Published private(set) var logModeEnabled = false
    @Published private(set) var photoFormat = "HEIF"
    @Published private(set) var photoSpeedMode: PhotoSpeedMode = .standard
    @Published private(set) var responsivePhotoCaptureSupported = false
    @Published private(set) var zeroShutterLagSupported = false
    @Published private(set) var fastPhotoCaptureSupported = false
    @Published private(set) var lenses: [CameraLensOption] = []
    @Published private(set) var selectedLensID = ""
    @Published private(set) var isFrontCamera = false
    /// Presentation-only preference for left/right selfie tracking. Saved
    /// media retains the camera's normal orientation.
    @Published private(set) var frontPreviewMirrored = false
    /// The neutral starting reference shown by InCam. Continuous Auto WB is
    /// still free to meter the scene, but it does not replace this baseline
    /// with noisy, misleading Kelvin/tint numbers in the UI.
    @Published var temperature: Float = 5_700
    @Published var tint: Float = 0
    @Published var exposureAuto = true
    /// The UI keeps Shutter and ISO independent. AVFoundation meters them as
    /// a pair only when *both* are Auto; changing one no longer flips the
    /// other's visible Auto/Manual state.
    @Published var shutterAuto = true
    @Published var isoAuto = true
    @Published private(set) var exposureLocked = false
    @Published private(set) var exposureBias: Float = 0
    private var exposureBiasRange: ClosedRange<Float> = -3...3
    @Published var whiteBalanceAuto = true
    @Published var tintAuto = true
    @Published private(set) var focusAuto = true
    @Published private(set) var focusPosition: Float = 0.5
    @Published var levelRoll: Double = 0
    @Published var levelPitch: Double = 0
    @Published private(set) var levelIsCentered = false
    @Published private(set) var health: CameraHealth = .ready
    @Published var lastError: String?
    @Published private(set) var audioInputs: [AudioInputOption] = []
    @Published private(set) var audioInputID = ""
    @Published private(set) var audioOutputName = "Unavailable"
    @Published private(set) var audioGain: Float = 1
    @Published private(set) var audioGainSupported = false
    @Published private(set) var audioLevels: [Float] = []
    @Published private(set) var audioStatus = "No microphone connected"
    @Published private(set) var audioChannelMode: AudioChannelMode = .stereo
    @Published private(set) var audioOutputMode: AudioOutputMode = .system
    @Published private(set) var recordingFolderName = "ENES"
    @Published private(set) var recordingPrefix = "INCAM"
    @Published private(set) var recordingNamingMode: RecordingNamingMode = .sequence
    /// True only while the on-demand Metal Color Mix renderer is presenting.
    /// Neutral shooting stays on AVCaptureVideoPreviewLayer alone.
    @Published private(set) var selectiveColorPreviewActive = false
    /// A compact, low-rate summary of the image for the optional Waveform or
    /// Histogram display. It is empty while scopes are Off, so the normal
    /// camera launch keeps its native preview-only path.
    @Published private(set) var sceneScopeSamples: [Float] = []
    /// RGB scope channels share the small sample grid above. Publishing them
    /// separately lets the monitor draw actual red, green, and blue traces.
    @Published private(set) var sceneScopeRedSamples: [Float] = []
    @Published private(set) var sceneScopeGreenSamples: [Float] = []
    @Published private(set) var sceneScopeBlueSamples: [Float] = []
    private var audioMeterTimer: DispatchSourceTimer?

    private let queue = DispatchQueue(label: "app.incam.capture", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let selectivePreviewOutput = AVCaptureVideoDataOutput()
    // A video-data callback must be serviced promptly or AVCapture begins
    // delivering stale frames. Work is GPU submission only; the output still
    // discards late frames instead of accumulating a backlog.
    private let selectivePreviewQueue = DispatchQueue(label: "app.incam.selective-color-preview", qos: .userInitiated)
    private let selectivePreviewSinkLock = NSLock()
    private weak var selectivePreviewSink: SelectiveColorPreviewSink?
    private let recipeLock = NSLock()
    private var cameraColorRecipe = CameraColorRecipe(name: "Custom Color")
    private var recordedRecipe = CameraColorRecipe(name: "Custom Color")
    /// Nil means guides are preview-only. A finite aspect is captured at the
    /// start of a shot so changing the UI guide cannot alter a clip in flight.
    private var outputFramingAspect: CGFloat?
    private var recordedOutputFramingAspect: CGFloat?
    private var selectivePreviewEnabled = false // Capture queue only.
    /// The shared video-data output also powers image scopes. It is opt-in and
    /// never attached merely because the home screen is visible.
    private var sceneScopeMode: SceneScopeMode = .off // Capture queue only.
    private var lastSceneScopeTimestamp = CMTime.invalid // Capture queue only.
    private var focusPeakingEnabled = false // Capture queue only.
    private var input: AVCaptureDeviceInput?
    private var timer: Timer?
    private var recordStartedAt: Date?
    private let motion = CMMotionManager()
    private let levelMotionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.incam.level-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private var levelMonitoringEnabled = false
    /// Core Motion reports attitude in the device's native portrait axes. The
    /// on-screen level must remap those axes to the active camera interface
    /// orientation before the overlay interprets them.
    private var levelInterfaceOrientation: UIInterfaceOrientation = .landscapeRight
    private var captureRotation: CGFloat = 0 // Capture queue only.
    /// The rear lens is remembered before entering the front camera. Camera
    /// discovery order is not a lens preference; on many phones its first
    /// back device is Ultra Wide, which caused a front → rear swap to land on
    /// the wrong lens.
    private var lastRearLensID: String?
    private var sessionConfigured = false // Capture queue only.
    private var zoomObservation: NSKeyValueObservation?
    private var exposureDurationObservation: NSKeyValueObservation?
    private var isoObservation: NSKeyValueObservation?
    private var whiteBalanceObservation: NSKeyValueObservation?
    private var zoomTimer: Timer?
    private var zoomVelocity: Double = 0
    private var pressureObservation: NSKeyValueObservation?
    private var sessionNotificationTokens: [NSObjectProtocol] = []
    private var shouldRun = false // Capture queue only.
    /// Optional capture features start after the basic viewfinder. This keeps
    /// the first SwiftUI interaction responsive instead of waiting on audio
    /// routing, photo tuning, capability discovery, and Metal setup.
    private var deferredSetupCompleted = false // Capture queue only.
    /// Advances whenever the viewfinder is stopped. Delayed startup work must
    /// check this before touching AVFoundation so a dismissed screen cannot
    /// revive audio, metering, or a session in the background.
    private var startupGeneration = 0 // Capture queue only.
    private var pressureThrottledPreview = false // Capture queue only.
    /// The auxiliary output is retained briefly after a scope/color/peaking
    /// tool closes. Reopening a tool during that interval avoids repeatedly
    /// reconfiguring a live capture session; releasing it after the grace
    /// period returns its bandwidth and power cost to the system.
    private var analysisOutputRemovalGeneration = 0 // Capture queue only.
    private var analysisDeliveryEnabled = false // Capture queue only.
    private let analysisOutputIdleGrace: TimeInterval = 3
    private let performance = CameraPerformanceInstrumentation()
    /// Prism-style gravity roll is filtered before publishing. Attitude Euler
    /// angles were the source of the previous level's unstable, backward
    /// movement near vertical device positions.
    private var filteredLevelRollRadians = 0.0
    private var levelCenteredOnMotionQueue = false
    private var lastLevelUIPublish = Date.distantPast

    override init() {
        super.init()
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        // v2 starts the phone-friendly zoom ceiling at 5×. Once the person
        // chooses a cap in Settings, that exact choice remains persistent.
        let savedZoomCap = UserDefaults.standard.double(forKey: "incam.zoom.cap.v2")
        zoomCap = savedZoomCap > 0 ? CGFloat(savedZoomCap) : 5
        let savedResolution = VideoResolution(rawValue: UserDefaults.standard.string(forKey: "incam.capture.resolution") ?? "")
        // Do not overwrite a saved 4K preference: it is retained for a later
        // reactivation, while this build uses the lighter 1080p path.
        videoResolution = AppFeatureAvailability.fourKCapture ? (savedResolution ?? .p4K) : .p1080
        let savedFrameRate = UserDefaults.standard.integer(forKey: "incam.capture.frame-rate.v1")
        frameRate = savedFrameRate > 0 ? savedFrameRate : 24
        videoCodec = VideoCodec(rawValue: UserDefaults.standard.string(forKey: "incam.capture.codec.v1") ?? "") ?? .hevc
        videoStabilization = VideoStabilization(rawValue: UserDefaults.standard.string(forKey: "incam.capture.stabilization.v1") ?? "") ?? .auto
        photoSpeedMode = PhotoSpeedMode(rawValue: UserDefaults.standard.string(forKey: "incam.photo.speed.v1") ?? "") ?? .standard
        shutterAngleMode = UserDefaults.standard.bool(forKey: "incam.shutter.angle-mode.v1")
        let savedAngle = UserDefaults.standard.double(forKey: "incam.manual.shutter.angle.v1")
        shutterAngleDegrees = CameraExposureDefaults.closestShutterAngle(savedAngle > 0 ? savedAngle : 180)
        frontPreviewMirrored = UserDefaults.standard.bool(forKey: "incam.front-preview-mirrored.v1")
        audioChannelMode = AudioChannelMode(rawValue: UserDefaults.standard.string(forKey: "incam.audio.channel-mode.v1") ?? "") ?? .stereo
        audioOutputMode = AudioOutputMode(rawValue: UserDefaults.standard.string(forKey: "incam.auddio.output-mode.v1") ?? "") ?? .system
        recordingFolderName = Self.cleanedFolderName(UserDefaults.standard.string(forKey: "incam.media.folder.v1") ?? "ENES")
        recordingPrefix = Self.cleanedPrefix(UserDefaults.standard.string(forKey: "incam.media.prefix.v1") ?? "INCAM")
        recordingNamingMode = RecordingNamingMode(rawValue: UserDefaults.standard.string(forKey: "incam.media.naming.v1") ?? "") ?? .sequence
        let savedShutter = UserDefaults.standard.double(forKey: "incam.manual.shutter.seconds.v1")
        if savedShutter.isFinite, savedShutter > 0,
           abs(savedShutter - CameraExposureDefaults.retiredShutterSeconds) > 0.000_001 {
            lastManualExposureSeconds = savedShutter
        } else {
            // Migrate the former 1/14 placeholder to the intended 4K/24
            // starting shutter. Explicit later manual choices still persist.
            UserDefaults.standard.set(CameraExposureDefaults.defaultShutterSeconds, forKey: "incam.manual.shutter.seconds.v1")
        }
        installSessionObservers()
    }

    deinit {
        pressureObservation?.invalidate()
        sessionNotificationTokens.forEach(NotificationCenter.default.removeObserver)
    }

    func start() {
        // STARTUP MAP: CameraScreen calls this when its live viewfinder appears.
        // UI state is published on Main; iOS camera work stays off the main
        // thread on `queue`, so starting the hardware should not freeze taps.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.health = self.isConfigured ? .ready : .starting
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = true
            if !self.session.isRunning {
                self.performance.recordStartupRequested()
            }
        }
        if levelMonitoringEnabled { startMotion() }
        #if targetEnvironment(simulator)
        // The simulator has no rear camera; keep the control workflow testable.
        authorization = .authorized
        audioStatus = "Microphone metering requires an iPhone"
        if lenses.isEmpty {
            lenses = [
                CameraLensOption(id: "demo.ultra", name: "Ultra Wide", equivalentMillimeters: 13, isPreview: true),
                CameraLensOption(id: "demo.wide", name: "Wide", equivalentMillimeters: 26, isPreview: true),
                CameraLensOption(id: "demo.tele", name: "Telephoto", equivalentMillimeters: 77, isPreview: true)
            ]
            selectedLensID = "demo.wide"
        }
        return
        #else
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { self?.authorization = granted ? .authorized : .denied }
                if granted { self?.configureIfNeeded() }
            }
        default:
            DispatchQueue.main.async {
                self.authorization = AVCaptureDevice.authorizationStatus(for: .video)
                self.health = .unavailable("Camera access is required to start the viewfinder.")
            }
        }
        #endif
    }

    /// Log is an intentional neutral workflow state. AVCapture's availability
    /// varies by iPhone, so this does not pretend to enable hardware Apple Log.
    // Stores whether the InCam recipe workflow should use its neutral Log-like mode.
    func setLogModeEnabled(_ enabled: Bool) {
        logModeEnabled = enabled
    }

    func stop() {
        // LIFECYCLE COST: this releases camera/mic/motion resources. It is
        // safe for backgrounding, but stopping for an in-app panel means that
        // returning must ask AVCaptureSession to resume its hardware again.
        stopZoomRamp()
        motion.stopDeviceMotionUpdates()
        stopTimer()
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRun = false
            self.startupGeneration &+= 1
            self.audioMeterTimer?.cancel()
            self.audioMeterTimer = nil
            // A camera session is the app's largest background cost. Finish an
            // active movie, then stop every capture stream when the scene is
            // hidden or backgrounded.
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            self.removeAnalysisOutputForStoppedSession()
            if self.session.isRunning { self.session.stopRunning() }
            // Stopping AVCaptureSession does not itself release the app's
            // audio route. Deactivate it while the camera is off screen.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            DispatchQueue.main.async {
                self.audioLevels = []
                self.audioStatus = "Microphone inactive"
                self.selectiveColorPreviewActive = false
                self.health = .starting
            }
        }
    }

    // Switches between still and video capture when a recording is not active.
    func toggleMode() {
        guard !isRecording else { return }
        mode = mode == .photo ? .video : .photo
    }

    // Routes the main capture button to a still photo, recording start, or recording stop.
    func capture() {
        #if targetEnvironment(simulator)
        lastError = "Use a physical iPhone to take photos or record video. The simulator supports the controls and layout only."
        return
        #else
        if mode == .photo {
            capturePhoto()
        } else if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
        #endif
    }

    // Saves the current interface rotation used by photo/movie output connections.
    func setCaptureRotation(_ angle: CGFloat) {
        queue.async { [weak self] in
            guard let self else { return }
            self.captureRotation = angle
            // The native preview layer rotates itself, while the Color Mix
            // video-data connection needs the same update explicitly.
            self.rotate(self.selectivePreviewOutput.connection(with: .video))
        }
    }

    /// Receives the draft from the color dock. It is read atomically on the
    /// capture queue so moving a color control changes preview frames safely.
    // Replaces the active Custom Color recipe and refreshes only its optional preview state.
    func setCameraColorRecipe(_ recipe: CameraColorRecipe) {
        var previewRecipe = recipe
        // Log workflow intentionally suspends global saturation/contrast
        // instead of allowing a hidden adjustment to alter the preview.
        if logModeEnabled {
            previewRecipe.saturation = 0
            previewRecipe.contrast = 0
        }
        recipeLock.lock()
        cameraColorRecipe = previewRecipe
        recipeLock.unlock()
        // Saving or loading a recipe must remain cheap. GPU presentation is
        // enabled explicitly when the Camera Colors tool is opened.
    }

    /// Camera Colors is an explicit opt-in for the direct-texture stream. A
    /// saved recipe alone must never make ordinary camera launch heavier.
    // Toggles the optional selective-color preview without claiming it alters saved video.
    func setCameraColorsPreviewEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.setSelectivePreviewEnabled(enabled && self.currentRecipe().hasVisibleAdjustments)
        }
    }

    /// Enables the lightweight scene analyser only for the selected scope.
    /// This shares the already-on-demand video-data output with Camera Colors
    /// rather than adding a permanent second capture stream.
    func setSceneScopeMode(_ mode: SceneScopeMode) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.sceneScopeMode != mode else { return }
            self.sceneScopeMode = mode
            self.lastSceneScopeTimestamp = .invalid
            self.updateSharedVideoDataOutput()
            if mode == .off {
                DispatchQueue.main.async {
                    self.sceneScopeSamples = []
                    self.sceneScopeRedSamples = []
                    self.sceneScopeGreenSamples = []
                    self.sceneScopeBlueSamples = []
                }
            }
        }
    }

    /// Applies viewfinder preferences before `start()` is queued. This is
    /// intentionally separate from the interactive setters: CameraScreen calls
    /// it first on appearance so a saved Histogram/Waveform can be attached in
    /// the initial session transaction instead of reconfiguring a live session
    /// just after its first preview frame.
    func prepareViewfinderStartup(scopeMode: SceneScopeMode, focusPeakingEnabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            let didDisableScope = self.sceneScopeMode != .off && scopeMode == .off
            self.sceneScopeMode = scopeMode
            self.lastSceneScopeTimestamp = .invalid
            self.focusPeakingEnabled = focusPeakingEnabled
            if self.sessionConfigured {
                self.updateSharedVideoDataOutput()
            }
            if didDisableScope {
                DispatchQueue.main.async {
                    self.sceneScopeSamples = []
                    self.sceneScopeRedSamples = []
                    self.sceneScopeGreenSamples = []
                    self.sceneScopeBlueSamples = []
                }
            }
        }
    }

    /// `AVCaptureVideoPreviewLayer.isPreviewing` is the closest native signal
    /// to a first visible preview frame without enabling an analysis stream in
    /// ordinary AF shooting. It is recorded as a measured preview-layer event,
    /// not as a claim about sensor exposure latency.
    func previewLayerDidBeginDisplayingFrames() {
        performance.recordPreviewLayerReady()
    }

    /// Focus peaking is an MF-only preview aid. It sends newest frames straight
    /// to the Metal presentation surface and never alters recorded movie frames.
    func setFocusPeakingEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.focusPeakingEnabled != enabled else {
                // The initial UI state can arrive before the capture session
                // is configured; retrying here attaches the stream once it is.
                self.updateSharedVideoDataOutput()
                return
            }
            self.focusPeakingEnabled = enabled
            self.updateSharedVideoDataOutput()
            self.setFocusPeakingPresentation(enabled)
        }
    }

    /// Attaches the direct-texture stream on demand. When it was just used, a
    /// short idle grace avoids a session rebuild while the person cycles scope
    /// modes. Its delegate is disabled immediately, and the whole output is
    /// removed after the grace interval to avoid paying an idle camera-stream
    /// bandwidth cost for ordinary shooting.
    // Applies the preview toggle on the serialized camera queue and updates the attached renderer.
    private func setSelectivePreviewEnabled(_ enabled: Bool) {
        guard sessionConfigured else { return }
        guard selectivePreviewEnabled != enabled else { return }
        selectivePreviewEnabled = enabled
        updateSharedVideoDataOutput()
        setSelectivePreviewPresentation(enabled)
    }

    /// Adds/removes the one optional AVCaptureVideoDataOutput used by Camera
    /// Colors, an active image scope, or MF focus peaking. Repeated tool
    /// toggles do not immediately rebuild the running AVCaptureSession: the
    /// callback is turned off at once, while removal waits briefly for a real
    /// idle period. All active modes discard late frames, so analysis cannot
    /// build a delayed preview backlog.
    private func updateSharedVideoDataOutput() {
        guard sessionConfigured else { return }
        let needsVideoData = needsVideoAnalysisOutput
        let attached = session.outputs.contains(selectivePreviewOutput)
        if needsVideoData {
            analysisOutputRemovalGeneration &+= 1
            if !attached {
                session.beginConfiguration()
                let attached = attachAnalysisOutputInCurrentConfiguration()
                session.commitConfiguration()
                guard attached else { return }
            }
            enableAnalysisDeliveryIfNeeded()
        } else {
            disableAnalysisDelivery()
            guard attached else { return }
            scheduleAnalysisOutputRemoval()
        }
    }

    private var needsVideoAnalysisOutput: Bool {
        selectivePreviewEnabled || sceneScopeMode != .off || focusPeakingEnabled
    }

    /// Configures the optional stream while the caller already owns a session
    /// configuration transaction. Keeping this separate lets first launch add
    /// a saved scope before `startRunning()`, rather than creating a second
    /// reconfiguration immediately after live video appears.
    @discardableResult
    private func attachAnalysisOutputInCurrentConfiguration() -> Bool {
        guard !session.outputs.contains(selectivePreviewOutput) else {
            enableAnalysisDeliveryIfNeeded()
            return true
        }
        guard session.canAddOutput(selectivePreviewOutput) else {
            publish(message: "Image analysis is unavailable with this camera format.")
            return false
        }
        selectivePreviewOutput.alwaysDiscardsLateVideoFrames = true
        // This stream is used only for on-screen assist features. It asks for
        // preview-sized buffers, but continues to use BGRA for now because the
        // current CPU scope and the existing focus-peaking renderer both depend
        // on it. Pixel-format changes require device profiling and correctness
        // checks before switching the shared path to bi-planar Y'CbCr.
        selectivePreviewOutput.automaticallyConfiguresOutputBufferDimensions = false
        selectivePreviewOutput.deliversPreviewSizedOutputBuffers = true
        selectivePreviewOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        session.addOutput(selectivePreviewOutput)
        rotate(selectivePreviewOutput.connection(with: .video))
        enableAnalysisDeliveryIfNeeded()
        return true
    }

    private func enableAnalysisDeliveryIfNeeded() {
        guard !analysisDeliveryEnabled else { return }
        selectivePreviewOutput.setSampleBufferDelegate(self, queue: selectivePreviewQueue)
        analysisDeliveryEnabled = true
    }

    private func disableAnalysisDelivery() {
        guard analysisDeliveryEnabled else { return }
        selectivePreviewOutput.setSampleBufferDelegate(nil, queue: nil)
        analysisDeliveryEnabled = false
    }

    private func scheduleAnalysisOutputRemoval() {
        analysisOutputRemovalGeneration &+= 1
        let generation = analysisOutputRemovalGeneration
        queue.asyncAfter(deadline: .now() + analysisOutputIdleGrace) { [weak self] in
            guard let self,
                  self.analysisOutputRemovalGeneration == generation,
                  !self.selectivePreviewEnabled,
                  self.sceneScopeMode == .off,
                  !self.focusPeakingEnabled,
                  self.session.outputs.contains(self.selectivePreviewOutput) else { return }
            self.session.beginConfiguration()
            self.session.removeOutput(self.selectivePreviewOutput)
            self.session.commitConfiguration()
        }
    }

    private func removeAnalysisOutputForStoppedSession() {
        analysisOutputRemovalGeneration &+= 1
        disableAnalysisDelivery()
        guard session.outputs.contains(selectivePreviewOutput) else { return }
        session.beginConfiguration()
        session.removeOutput(selectivePreviewOutput)
        session.commitConfiguration()
    }

    /// The presentation sink is a UIKit/Metal view layered directly over the
    /// preview layer. The capture controller owns no UI and retains it weakly.
    // Connects or disconnects the UIKit/Metal preview receiver from this controller.
    func setSelectivePreviewSink(_ sink: SelectiveColorPreviewSink?) {
        selectivePreviewSinkLock.lock()
        selectivePreviewSink = sink
        let active = selectivePreviewEnabled
        let focusPeakingActive = focusPeakingEnabled
        let frameRate = pressureThrottledPreview ? 15 : 30
        selectivePreviewSinkLock.unlock()
        sink?.setSelectiveColorPreviewActive(active)
        sink?.setFocusPeakingPreviewActive(focusPeakingActive)
        sink?.setSelectiveColorPreviewFrameRate(frameRate)
    }

    // Publishes whether SwiftUI should show the selective preview surface over the normal preview.
    private func setSelectivePreviewPresentation(_ active: Bool) {
        selectivePreviewSinkLock.lock()
        let sink = selectivePreviewSink
        selectivePreviewSinkLock.unlock()
        sink?.setSelectiveColorPreviewActive(active)
        DispatchQueue.main.async { self.selectiveColorPreviewActive = active }
    }

    // Enables the GPU peaking presentation independently from Color Mix.
    private func setFocusPeakingPresentation(_ active: Bool) {
        selectivePreviewSinkLock.lock()
        let sink = selectivePreviewSink
        selectivePreviewSinkLock.unlock()
        sink?.setFocusPeakingPreviewActive(active)
    }

    // Limits the optional preview renderer to a safe frame rate instead of processing every frame.
    private func setSelectivePreviewFrameRate(_ framesPerSecond: Int) {
        selectivePreviewSinkLock.lock()
        let sink = selectivePreviewSink
        selectivePreviewSinkLock.unlock()
        sink?.setSelectiveColorPreviewFrameRate(framesPerSecond)
    }

    // Selects a camera-supported still format and persists the person's choice.
    func setPhotoFormat(_ format: String) {
        guard capabilities.photoFormats.contains(format) else { return }
        photoFormat = format
    }

    /// A user-facing ceiling for both camcorder dragging and +/- buttons.
    /// Hardware limits remain a second, stricter ceiling when necessary.
    // Changes the user-facing maximum zoom while respecting the active lens hardware limit.
    func setZoomCap(_ requested: CGFloat) {
        let cap = min(10, max(1, requested))
        zoomCap = cap
        UserDefaults.standard.set(Double(cap), forKey: "incam.zoom.cap.v2")
        if zoom > cap { setZoom(cap) }
    }

    /// A spring-centered rocker: displacement controls velocity, not zoom position.
    // Stores the speed used by hold-to-zoom controls; it does not move the lens itself.
    func setZoomVelocity(_ requested: Double) {
        let velocity = min(1, max(-1, requested))
        guard abs(velocity) > 0.04 else { stopZoomRamp(); return }
        zoomVelocity = velocity
        #if targetEnvironment(simulator)
        if zoomTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                let rate = (self.zoomVelocity < 0 ? -1.0 : 1.0) * pow(abs(self.zoomVelocity), 1.5) * 2
                self.zoom = min(10, max(1, self.zoom * CGFloat(pow(2, rate / 30))))
            }
            zoomTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        #else
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                let target = velocity > 0 ? min(self.zoomCap, device.maxAvailableVideoZoomFactor) : device.minAvailableVideoZoomFactor
                let magnitude = abs(velocity)
                // Smoothstep gives the camcorder control a gentle start and
                // finish instead of a linear response as the thumb moves.
                let sCurve = magnitude * magnitude * (3 - 2 * magnitude)
                device.ramp(toVideoZoomFactor: target, withRate: Float(0.1 + sCurve * 3))
                device.unlockForConfiguration()
            } catch { self.publish(error) }
        }
        #endif
    }

    // Stops any in-progress hardware zoom ramp and clears its queued work item.
    func stopZoomRamp() {
        zoomVelocity = 0
        zoomTimer?.invalidate()
        zoomTimer = nil
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                let value = device.videoZoomFactor
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoom = value }
            } catch { self.publish(error) }
        }
    }

    // Switches the session input to a chosen physical front/rear lens on the camera queue.
    func selectLens(_ id: String) {
        guard !isRecording, id != selectedLensID, lenses.contains(where: { $0.id == id }) else { return }
        stopZoomRamp()
        #if targetEnvironment(simulator)
        selectedLensID = id
        zoom = 1
        return
        #else
        queue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording, let oldInput = self.input,
                  let device = Self.physicalCameras().first(where: { $0.uniqueID == id }) else { return }
            do {
                let replacement = try AVCaptureDeviceInput(device: device)
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, 1))
                device.unlockForConfiguration()
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                guard self.session.canAddInput(replacement) else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    throw CameraFailure.configuration
                }
                self.session.addInput(replacement)
                self.input = replacement
                self.session.commitConfiguration()
                self.rotate(self.selectivePreviewOutput.connection(with: .video))
                self.observeZoom(device)
                self.observeAutoReadouts(device)
                self.readCapabilities(device)
                DispatchQueue.main.async {
                    self.selectedLensID = id
                    self.lastRearLensID = id
                    UserDefaults.standard.set(id, forKey: "incam.last-rear-lens.v1")
                    self.whiteBalanceAuto = true
                    self.tintAuto = true
                    self.exposureAuto = true
                    self.shutterAuto = true
                    self.isoAuto = true
                    self.exposureLocked = false
                    self.exposureBias = 0
                }
            } catch { self.publish(error) }
        }
        #endif
    }

    /// Moves one physical lens at a time. Reaching the widest or tightest
    /// lens is a no-op, so a camera-surface pinch never starts digital zoom.
    // Finds the adjacent physical lens in focal-length order and delegates to selectLens.
    func cycleLens(towardTelephoto: Bool) {
        guard !isRecording else { return }
        let ordered = lenses.sorted {
            ($0.equivalentMillimeters ?? 0) < ($1.equivalentMillimeters ?? 0)
        }
        guard let current = ordered.firstIndex(where: { $0.id == selectedLensID }) else { return }
        let next = current + (towardTelephoto ? 1 : -1)
        guard ordered.indices.contains(next) else { return }
        selectLens(ordered[next].id)
    }

    /// Controls whether the selected composition guide is also applied to
    /// saved stills and the post-recording movie export. It is intentionally
    /// opt-in: guides alone remain non-destructive composition tools.
    // Stores the requested output framing aspect used later by the save/export path.
    func setOutputFraming(aspect: CGFloat?) {
        let validAspect = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        recipeLock.lock()
        outputFramingAspect = validAspect
        recipeLock.unlock()
    }

    /// Swaps between the front wide camera and the current rear camera only
    /// while idle. Each side is a real AVCaptureDevice input—this is never a
    /// mirrored software approximation of the rear feed.
    // Switches between rear and front camera positions while preserving a valid available lens.
    func toggleCameraPosition() {
        guard !isRecording else { return }
        stopZoomRamp()
        #if targetEnvironment(simulator)
        isFrontCamera.toggle()
        zoom = 1
        #else
        queue.async { [weak self] in
            guard let self, !self.movieOutput.isRecording, let oldInput = self.input else { return }
            let nextPosition: AVCaptureDevice.Position = oldInput.device.position == .front ? .back : .front
            if oldInput.device.position == .back {
                self.lastRearLensID = oldInput.device.uniqueID
                UserDefaults.standard.set(oldInput.device.uniqueID, forKey: "incam.last-rear-lens.v1")
            }
            let candidates = Self.physicalCameras(position: nextPosition)
            let rememberedRearID = self.lastRearLensID
                ?? UserDefaults.standard.string(forKey: "incam.last-rear-lens.v1")
            let device = nextPosition == .back
                ? (candidates.first(where: { $0.uniqueID == rememberedRearID })
                   ?? candidates.first(where: { $0.deviceType == .builtInWideAngleCamera })
                   ?? candidates.first)
                : candidates.first
            guard let device else {
                self.publish(message: nextPosition == .front ? "No front camera is available." : "No rear camera is available.")
                return
            }
            do {
                let replacement = try AVCaptureDeviceInput(device: device)
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, 1)
                device.unlockForConfiguration()
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                guard self.session.canAddInput(replacement) else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    throw CameraFailure.configuration
                }
                self.session.addInput(replacement)
                self.input = replacement
                self.session.commitConfiguration()
                self.rotate(self.selectivePreviewOutput.connection(with: .video))
                self.observeZoom(device)
                self.observeAutoReadouts(device)
                self.readCapabilities(device)
                let options = Self.physicalCameras(position: nextPosition).map(Self.lensOption)
                DispatchQueue.main.async {
                    self.lenses = options
                    self.selectedLensID = device.uniqueID
                    self.isFrontCamera = nextPosition == .front
                    if nextPosition == .back {
                        self.lastRearLensID = device.uniqueID
                        UserDefaults.standard.set(device.uniqueID, forKey: "incam.last-rear-lens.v1")
                    }
                    self.whiteBalanceAuto = true
                    self.tintAuto = true
                    self.exposureAuto = true
                    self.shutterAuto = true
                    self.isoAuto = true
                    self.exposureLocked = false
                    self.exposureBias = 0
                }
            } catch { self.publish(error) }
        }
        #endif
    }

    // Converts AVFoundation device information into the compact lens data used by the UI.
    private static func lensOption(_ device: AVCaptureDevice) -> CameraLensOption {
        let fieldOfView = Double(device.activeFormat.videoFieldOfView)
        // 36 mm is the horizontal width of a 35 mm still frame. This is a
        // field-of-view estimate, not the phone lens's physical focal length
        // or a manufacturer-calibrated value; the UI explicitly marks it ≈.
        let equivalent = fieldOfView > 0 && fieldOfView < 179
            ? Int((36 / (2 * tan(fieldOfView * .pi / 360))).rounded()) : nil
        let name = device.deviceType == .builtInUltraWideCamera ? "Ultra Wide"
            : (device.deviceType == .builtInTelephotoCamera ? "Telephoto" : "Wide")
        return CameraLensOption(id: device.uniqueID, name: name, equivalentMillimeters: equivalent)
    }

    // Returns the real physical cameras for a position, excluding virtual composite devices.
    private static func physicalCameras(position: AVCaptureDevice.Position = .back) -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                                        mediaType: .video, position: position).devices
    }

    // Observes device zoom changes so the published UI value follows hardware ramps and gestures.
    private func observeZoom(_ device: AVCaptureDevice) {
        zoomObservation = device.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] device, _ in
            let value = device.videoZoomFactor
            DispatchQueue.main.async { self?.zoom = value }
        }
    }

    /// Mirrors the physical camera's automatic metering in the readouts.
    /// Each observer ignores updates immediately after a manual edit, so the
    /// live Auto values never overwrite an intentional shutter/ISO/WB choice.
    // Observes auto-metered exposure/focus values and safely republishes them for SwiftUI.
    private func observeAutoReadouts(_ device: AVCaptureDevice) {
        exposureDurationObservation?.invalidate()
        isoObservation?.invalidate()
        whiteBalanceObservation?.invalidate()

        exposureDurationObservation = device.observe(\.exposureDuration, options: [.initial, .new]) { [weak self] device, _ in
            let seconds = CMTimeGetSeconds(device.exposureDuration)
            DispatchQueue.main.async {
                guard let self, self.shutterAuto, seconds.isFinite, seconds > 0 else { return }
                self.exposureSeconds = seconds
            }
        }
        isoObservation = device.observe(\.iso, options: [.initial, .new]) { [weak self] device, _ in
            let value = device.iso
            DispatchQueue.main.async {
                guard let self, self.isoAuto, value.isFinite else { return }
                self.iso = value
            }
        }
        whiteBalanceObservation = device.observe(\.deviceWhiteBalanceGains, options: [.initial, .new]) { [weak self] device, _ in
            let values = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            DispatchQueue.main.async {
                guard let self else { return }
                if self.whiteBalanceAuto { self.temperature = values.temperature }
                if self.tintAuto { self.tint = values.tint }
            }
        }
    }

    /// Thumb-ruler zoom. The published value updates even in Simulator so the
    /// control can be reviewed without a camera; a physical device clamps to
    /// the active lens/format range before applying it.
    // Clamps a requested zoom to the active lens range and applies it under the device configuration lock.
    func setZoom(_ requested: CGFloat) {
        #if targetEnvironment(simulator)
        let previewMaximum: CGFloat = zoomCap
        #else
        let previewMaximum = min(capabilities.maxZoom, zoomCap)
        #endif
        let previewValue = min(previewMaximum, max(capabilities.minZoom, requested))
        DispatchQueue.main.async { self.zoom = previewValue }
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                let target = min(device.maxAvailableVideoZoomFactor,
                                 max(device.minAvailableVideoZoomFactor, requested))
                device.ramp(toVideoZoomFactor: target, withRate: 4)
                device.unlockForConfiguration()
            } catch { self.publish(error) }
        }
    }

    // Chooses a valid active format and frame duration for the requested FPS; this can reconfigure hardware.
    func setFrameRate(_ requested: Int) {
        guard !isRecording else { return }
        frameRate = requested
        UserDefaults.standard.set(requested, forKey: "incam.capture.frame-rate.v1")
        // Angle mode preserves the selected angle. For example, 360° is
        // 1/24 s at 24 fps and 1/60 s at 60 fps. Speed mode keeps its normal
        // 180°-style baseline (24 fps -> 1/50).
        let matchingShutter = shutterAngleMode
            ? shutterAngleDegrees / (Double(max(1, requested)) * 360)
            : CameraExposureDefaults.recommendedShutterSeconds(for: requested)
        let supportedShutter = capabilities.manualExposure(matchingShutter)
        lastManualExposureSeconds = supportedShutter
        exposureSeconds = supportedShutter
        shutterAuto = false
        exposureAuto = false
        UserDefaults.standard.set(exposureSeconds, forKey: "incam.manual.shutter.seconds.v1")
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            guard let format = Self.preferredFormat(for: device,
                                                     resolution: self.videoResolution,
                                                     frameRate: requested) else {
                self.publish(message: "\(self.videoResolution.rawValue) \(requested) fps is not available on this lens.")
                return
            }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: CMTimeScale(requested))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                self.readCapabilities(device)
                self.applyExposure()
            } catch { self.publish(error) }
        }
    }

    /// Double-tapping any shutter control toggles the display without altering
    /// the selected shutter duration or changing exposure mode.
    // Changes only the shutter dial representation between speed and angle, then reapplies manual duration.
    func toggleShutterAngleMode() {
        shutterAngleMode.toggle()
        if shutterAngleMode {
            shutterAngleDegrees = CameraExposureDefaults.closestShutterAngle(
                lastManualExposureSeconds * Double(max(1, frameRate)) * 360
            )
            UserDefaults.standard.set(shutterAngleDegrees, forKey: "incam.manual.shutter.angle.v1")
        }
        UserDefaults.standard.set(shutterAngleMode, forKey: "incam.shutter.angle-mode.v1")
    }

    /// Changes output resolution only while idle. AVFoundation may expose a
    /// different set per device, lens, and active session configuration.
    // Changes session preset/resolution after verifying that the active session can support it.
    func setVideoResolution(_ requested: VideoResolution) {
        guard !isRecording,
              (AppFeatureAvailability.fourKCapture || requested != .p4K),
              availableVideoResolutions.contains(requested) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let preset = Self.sessionPreset(for: requested)
            guard self.session.canSetSessionPreset(preset) else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = preset
            self.session.commitConfiguration()
            if let device = self.input?.device { self.readCapabilities(device, resolution: requested) }
            DispatchQueue.main.async {
                self.videoResolution = requested
                UserDefaults.standard.set(requested.rawValue, forKey: "incam.capture.resolution")
            }
        }
    }

    /// Applies a video codec that the active MovieFileOutput explicitly lists.
    // Selects a supported movie codec and updates the movie output settings on the camera queue.
    func setVideoCodec(_ requested: VideoCodec) {
        guard !isRecording, availableVideoCodecs.contains(requested) else { return }
        queue.async { [weak self] in
            guard let self, let connection = self.movieOutput.connection(with: .video) else { return }
            let nativeCodec = Self.nativeCodec(for: requested)
            guard self.movieOutput.availableVideoCodecTypes.contains(nativeCodec),
                  self.movieOutput.supportedOutputSettingsKeys(for: connection).contains(AVVideoCodecKey) else { return }
            self.movieOutput.setOutputSettings([AVVideoCodecKey: nativeCodec], for: connection)
            DispatchQueue.main.async {
                self.videoCodec = requested
                UserDefaults.standard.set(requested.rawValue, forKey: "incam.capture.codec.v1")
            }
        }
    }

    /// HDR is disabled unless this exact device format says that it supports
    /// controllable extended-dynamic-range video.
    // Enables HDR only when the active camera format reports that it supports HDR video.
    func setVideoHDREnabled(_ enabled: Bool) {
        guard !isRecording, videoHDRSupported else { return }
        queue.async { [weak self] in
            guard let self, let device = self.input?.device,
                  device.activeFormat.isVideoHDRSupported else { return }
            do {
                try device.lockForConfiguration()
                device.automaticallyAdjustsVideoHDREnabled = false
                device.isVideoHDREnabled = enabled
                let active = device.isVideoHDREnabled
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.videoHDREnabled = active }
            } catch { self.publish(error) }
        }
    }

    /// Sets only a mode that the current MovieFileOutput connection confirms
    /// it can use. A lens or format change can remove a mode at any time.
    // Persists a stabilization choice and applies it to the movie connection when supported.
    func setVideoStabilization(_ requested: VideoStabilization) {
        guard !isRecording, availableVideoStabilizations.contains(requested) else { return }
        queue.async { [weak self] in
            guard let self,
                  let connection = self.movieOutput.connection(with: .video),
                  let device = self.input?.device else { return }
            let native = Self.nativeStabilization(for: requested)
            guard requested == .off || (connection.isVideoStabilizationSupported && device.activeFormat.isVideoStabilizationModeSupported(native)) else { return }
            connection.preferredVideoStabilizationMode = native
            DispatchQueue.main.async {
                // `activeVideoStabilizationMode` can briefly report Off while
                // a connection is starting. Keep the person's supported
                // preference rather than silently losing it during launch.
                self.videoStabilization = requested
                UserDefaults.standard.set(requested.rawValue, forKey: "incam.capture.stabilization.v1")
            }
        }
    }

    /// Responsive still capture is opt-in because it reserves extra photo
    /// buffers. Deferred Photo delivery intentionally remains off: its final
    /// image is completed through Photos, not InCam's private gallery.
    // Chooses standard or responsive still behavior and updates compatible photo-output features.
    func setPhotoSpeedMode(_ requested: PhotoSpeedMode) {
        guard !isRecording else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configurePhotoSpeedCapture(requested)
            self.session.commitConfiguration()
        }
    }

    // Makes ISO manual and applies the requested value while preserving shutter's independent auto state.
    func setISO(_ newISO: Float) {
        guard newISO.isFinite else { return }
        exposureLocked = false
        exposureBias = 0
        // Keep the approved discrete ISO stop intact (125, 160, 640, etc.).
        // The active lens remains the source of truth for the final clamp.
        iso = capabilities.manualISO(newISO)
        isoAuto = false
        exposureAuto = shutterAuto && isoAuto
        applyExposure()
    }

    // Makes shutter manual, clamps the duration to the active format and applies combined exposure settings.
    func setExposure(_ seconds: Double) {
        guard seconds.isFinite else { return }
        exposureLocked = false
        exposureBias = 0
        exposureSeconds = capabilities.manualExposure(seconds)
        lastManualExposureSeconds = exposureSeconds
        UserDefaults.standard.set(exposureSeconds, forKey: "incam.manual.shutter.seconds.v1")
        shutterAuto = false
        exposureAuto = shutterAuto && isoAuto
        applyExposure()
    }

    /// Applies the actual duration for an angle at the active frame rate.
    /// Increasing angle lengthens the shutter and increases motion blur; it
    /// does not increase the movie's recorded frame rate.
    // Converts an angle and current FPS into a manual exposure duration, capped by camera support.
    func setShutterAngle(_ degrees: Double) {
        let angle = CameraExposureDefaults.closestShutterAngle(degrees)
        shutterAngleDegrees = angle
        UserDefaults.standard.set(angle, forKey: "incam.manual.shutter.angle.v1")
        setExposure(angle / (Double(max(1, frameRate)) * 360))
    }

    // Stores the display-only selfie mirror preference; it does not rotate or rewrite saved media.
    func setFrontPreviewMirrored(_ enabled: Bool) {
        frontPreviewMirrored = enabled
        UserDefaults.standard.set(enabled, forKey: "incam.front-preview-mirrored.v1")
    }

    // Changes shutter automation only, then recalculates AVFoundation exposure automation.
    func setShutterAuto(_ enabled: Bool) {
        shutterAuto = enabled
        updateExposureAutomation()
    }

    // Changes ISO automation only, then recalculates AVFoundation exposure automation.
    func setISOAuto(_ enabled: Bool) {
        isoAuto = enabled
        updateExposureAutomation()
    }

    // Sets shutter and ISO automation together for the master exposure Auto control.
    func setExposureAuto(_ enabled: Bool) {
        exposureLocked = false
        exposureBias = 0
        shutterAuto = enabled
        isoAuto = enabled
        exposureAuto = enabled
        if !enabled { applyExposure(); return }
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                guard device.isExposureModeSupported(.continuousAutoExposure) else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async {
                        self.exposureAuto = false
                        self.lastError = "Automatic exposure is not supported by this camera."
                    }
                    return
                }
                device.exposureMode = .continuousAutoExposure
                device.setExposureTargetBias(0, completionHandler: nil)
                let liveISO = device.iso
                let liveDuration = CMTimeGetSeconds(device.exposureDuration)
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    // Switching Auto means the hardware meters brightness
                    // again. Mirror that immediately instead of leaving a
                    // stale manual readout on screen.
                    self.iso = liveISO
                    self.exposureSeconds = liveDuration
                    self.exposureAuto = true
                }
            } catch { self.publish(error) }
        }
    }

    /// Lock the current metered exposure, not stale values from the manual dials.
    // Locks or unlocks the current metering point without changing the chosen manual controls.
    func toggleExposureLock() {
        if exposureLocked { setExposureAuto(true); return }
        lockExposure(at: nil)
    }

    /// Locks exposure at a point selected in the live preview. Repeated taps
    /// preserve the existing lock while moving the hardware point of interest;
    /// they never accidentally unlock exposure.
    // Locks auto exposure/white balance at a normalized preview point and records the visible lock state.
    func lockExposure(at point: CGPoint?) {
        let validPoint = point.flatMap { point in
            point.x.isFinite && point.y.isFinite
                ? CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)) )
                : nil
        }
        #if targetEnvironment(simulator)
        exposureLocked = true
        exposureAuto = false
        shutterAuto = false
        isoAuto = false
        exposureBias = 0
        #else
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            guard device.isExposureModeSupported(.locked) else {
                DispatchQueue.main.async { self.lastError = "This camera does not support exposure lock." }
                return
            }
            do {
                try device.lockForConfiguration()
                if let validPoint, device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = validPoint
                }
                device.exposureMode = .locked
                let currentISO = device.iso
                let duration = CMTimeGetSeconds(device.exposureDuration)
                let bias = device.exposureTargetBias
                let range = device.minExposureTargetBias...device.maxExposureTargetBias
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.iso = currentISO
                    self.exposureSeconds = duration
                    self.exposureBiasRange = range
                    self.exposureBias = bias
                    self.exposureAuto = false
                    self.shutterAuto = false
                    self.isoAuto = false
                    self.exposureLocked = true
                }
            } catch { self.publish(error) }
        }
        #endif
    }

    // Steps locked auto-exposure compensation by a small EV amount through the shared clamp function.
    func adjustExposureBias(by delta: Float) {
        guard exposureLocked, delta.isFinite else { return }
        setExposureBias(exposureBias + delta)
    }

    var exposureDialRange: ClosedRange<Double> {
        // Keep the requested cinema-style −3...+3 EV window, while never
        // claiming values that the current physical lens does not expose.
        let lower = max(-3.0, ceil(Double(exposureBiasRange.lowerBound) * 10) / 10)
        let upper = min(3.0, floor(Double(exposureBiasRange.upperBound) * 10) / 10)
        return lower <= upper ? lower...upper : 0...0
    }

    // Clamps and applies EV bias to the active device while keeping the UI value in sync.
    func setExposureBias(_ requested: Float) {
        guard exposureLocked, requested.isFinite else { return }
        let lower = Float(exposureDialRange.lowerBound)
        let upper = Float(exposureDialRange.upperBound)
        guard lower <= upper else { return }
        let target = min(upper, max(lower, (requested * 10).rounded() / 10))
        exposureBias = abs(target) < 0.001 ? 0 : target
        #if !targetEnvironment(simulator)
        queue.async { [weak self] in
            guard let self, let device = self.input?.device, device.exposureMode == .locked else { return }
            do {
                try device.lockForConfiguration()
                // AE compensation must not rewrite the manual ISO/shutter
                // readouts. They remain the values present when AE was locked.
                device.setExposureTargetBias(target, completionHandler: nil)
                device.unlockForConfiguration()
            } catch { self.publish(error) }
        }
        #endif
    }

    // Makes white balance/tint manual together and applies the requested temperature/tint gains.
    func setWhiteBalance(temperature: Float, tint: Float) {
        self.temperature = temperature
        self.tint = tint
        whiteBalanceAuto = false
        tintAuto = false
        applyWhiteBalance()
    }

    // Makes only white-balance temperature manual and reapplies the combined white-balance setting.
    func setTemperature(_ temperature: Float) {
        self.temperature = temperature
        whiteBalanceAuto = false
        updateWhiteBalanceAutomation()
    }

    // Makes only tint manual and reapplies the combined white-balance setting.
    func setTint(_ tint: Float) {
        self.tint = tint
        tintAuto = false
        updateWhiteBalanceAutomation()
    }

    // Toggles continuous automatic white balance without changing tint's independent state.
    func setWhiteBalanceAuto(_ enabled: Bool) {
        whiteBalanceAuto = enabled
        updateWhiteBalanceAutomation()
    }

    // Toggles tint's automatic behavior without changing temperature's independent state.
    func setTintAuto(_ enabled: Bool) {
        tintAuto = enabled
        updateWhiteBalanceAutomation()
    }

    // Computes the valid AVFoundation exposure mode from separate shutter/ISO Auto choices.
    private func updateExposureAutomation() {
        let shouldMeterBoth = shutterAuto && isoAuto
        exposureLocked = false
        exposureBias = 0
        exposureAuto = shouldMeterBoth
        if !shouldMeterBoth { applyExposure(); return }
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                guard device.isExposureModeSupported(.continuousAutoExposure) else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async {
                        self.exposureAuto = false
                        self.shutterAuto = false
                        self.isoAuto = false
                        self.lastError = "Automatic exposure is not supported by this camera."
                    }
                    return
                }
                device.exposureMode = .continuousAutoExposure
                device.setExposureTargetBias(0, completionHandler: nil)
                let liveISO = device.iso
                let liveDuration = CMTimeGetSeconds(device.exposureDuration)
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.iso = liveISO
                    self.exposureSeconds = liveDuration
                    self.exposureAuto = true
                }
            } catch { self.publish(error) }
        }
    }

    // Computes whether device white balance should be continuous auto or locked from independent controls.
    private func updateWhiteBalanceAutomation() {
        let shouldMeterBoth = whiteBalanceAuto && tintAuto
        // Returning to Auto restores a clear neutral UI reference instead of
        // exposing transient sensor-gain conversions as false Kelvin values.
        if !shouldMeterBoth { applyWhiteBalance(); return }
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            do {
                try device.lockForConfiguration()
                guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else {
                    device.unlockForConfiguration()
                    DispatchQueue.main.async {
                        self.whiteBalanceAuto = false
                        self.tintAuto = false
                        self.lastError = "Automatic white balance is not supported by this camera."
                    }
                    return
                }
                device.whiteBalanceMode = .continuousAutoWhiteBalance
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.temperature = 5_700
                    self.tint = 0
                    self.whiteBalanceAuto = true
                    self.tintAuto = true
                }
            } catch { self.publish(error) }
        }
    }

    /// AF follows the tapped area; MF performs one focus scan and then holds it.
    // Performs a one-time focus action at a normalized device-space point when the lens supports it.
    func focus(at point: CGPoint) {
        guard point.x.isFinite, point.y.isFinite else { return }
        let auto = focusAuto
        #if !targetEnvironment(simulator)
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            let focusMode: AVCaptureDevice.FocusMode = auto ? .continuousAutoFocus : .autoFocus
            guard device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) else {
                DispatchQueue.main.async {
                    // Fixed-focus Ultra Wide and front lenses cannot accept a
                    // point of interest. Say what happened and preserve the
                    // selected lens rather than silently swapping lenses.
                    self.lastError = "This selected lens has fixed focus. Switch to a focus-capable Wide lens to tap-to-focus."
                }
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.focusPointOfInterest = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
                device.focusMode = focusMode
                // Do not change exposurePointOfInterest or exposureMode here.
            } catch { self.publish(error) }
        }
        #endif
    }

    // Switches between continuous autofocus and a manual lens position on the active device.
    func setFocus(auto: Bool, position: Float? = nil) {
        #if targetEnvironment(simulator)
        focusAuto = auto
        if let position { focusPosition = min(1, max(0, position)) }
        #else
        queue.async { [weak self] in
            guard let self, let device = self.input?.device else { return }
            let mode: AVCaptureDevice.FocusMode = auto ? .continuousAutoFocus : .locked
            guard device.isFocusModeSupported(mode) else {
                DispatchQueue.main.async { self.lastError = "This lens does not support the selected focus mode." }
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if !auto, let position, device.isLockingFocusWithCustomLensPositionSupported {
                    device.setFocusModeLocked(lensPosition: min(1, max(0, position)), completionHandler: nil)
                } else { device.focusMode = mode }
                let lensPosition = device.lensPosition
                DispatchQueue.main.async { self.focusAuto = auto; self.focusPosition = position ?? lensPosition }
            } catch { self.publish(error) }
        }
        #endif
    }

    private func configureIfNeeded() {
        // FAST PATH: an existing configured session only resumes. FIRST OPEN:
        // iOS allocates a physical lens and attaches photo/movie outputs here.
        // The saved format, audio route (when already authorized), codec,
        // stabilization, and optional scope output are chosen in this single
        // transaction. Starting first and changing them afterward visibly
        // hitches the viewfinder on iPhone 11-class hardware.
        queue.async { [weak self] in
            guard let self, !self.sessionConfigured else {
                guard let self else { return }
                if self.session.isRunning == false {
                    // `stop()` releases the optional analysis output to save
                    // background power. Restore an enabled saved scope before
                    // resuming flow, so a returning viewfinder does not first
                    // show video and then reconfigure itself.
                    self.updateSharedVideoDataOutput()
                    self.session.startRunning()
                }
                if self.deferredSetupCompleted {
                    self.activateAudioSession()
                    self.startAudioMetering()
                } else {
                    self.scheduleDeferredCaptureSetup()
                }
                self.setSelectivePreviewPresentation(self.selectivePreviewEnabled)
                return
            }
            self.session.beginConfiguration()
            let preferredPreset = Self.sessionPreset(for: self.videoResolution)
            self.session.sessionPreset = self.session.canSetSessionPreset(preferredPreset) ? preferredPreset : .high

            let devices = Self.physicalCameras()
                guard let device = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first else {
                    self.session.commitConfiguration()
                    self.publish(message: "No rear camera is available.")
                    DispatchQueue.main.async {
                        self.health = .unavailable("No compatible rear camera is available.")
                    }
                    return
                }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else { throw CameraFailure.configuration }
                self.session.addInput(input)
                self.input = input
                self.lastRearLensID = device.uniqueID
                UserDefaults.standard.set(device.uniqueID, forKey: "incam.last-rear-lens.v1")
                self.observeZoom(device)
                self.observeAutoReadouts(device)
                let options = devices.map(Self.lensOption)
                DispatchQueue.main.async { self.lenses = options; self.selectedLensID = device.uniqueID }

                if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
                if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
                self.configureInitialVideoFormat(device)
                self.configurePhotoSpeedCapture(self.photoSpeedMode)
                self.configurePreferredVideoCodec()
                // If mic permission was previously granted, joining it before
                // the first start prevents a second live-session transaction.
                // A new permission prompt still resolves asynchronously and is
                // the unavoidable exception to this fast path.
                self.configureAudio()
                self.applyVideoStabilization()
                if self.needsVideoAnalysisOutput {
                    _ = self.attachAnalysisOutputInCurrentConfiguration()
                }
                self.session.commitConfiguration()
                self.sessionConfigured = true
                self.observeDeviceHealth(device)
                DispatchQueue.main.async {
                    self.isConfigured = true
                    self.health = .ready
                }
                self.session.startRunning()
                self.scheduleDeferredCaptureSetup()
            } catch {
                self.session.commitConfiguration()
                self.publish(error)
                DispatchQueue.main.async {
                    self.health = .unavailable("Camera could not start. Try closing another app that is using it.")
                }
            }
        }
    }

    /// The first camera frame and its essential controls win startup. Audio
    /// routing, format inspection, stabilization discovery and photo tuning
    /// are deliberately delayed until the viewfinder has had time to become
    /// interactive. This follows the staged-start pattern used by the faster
    /// open-source camera apps, without lowering recording quality.
    private func scheduleDeferredCaptureSetup() {
        // DELIBERATE 0.75 s STAGE: only non-hardware metadata waits for the
        // first preview. Format/FPS, audio attachment, stabilization, codec
        // and photo tuning were already configured before startRunning(), so
        // this stage must never create the former second preview hitch.
        let generation = startupGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self,
                      self.shouldRun,
                      self.sessionConfigured,
                      !self.deferredSetupCompleted,
                      self.startupGeneration == generation,
                      let device = self.input?.device else { return }

                // Capability discovery updates the inspector after the first
                // frame but does not mutate the running capture configuration.
                self.readCapabilities(device)
                self.deferredSetupCompleted = true
                self.startAudioMetering()
            }
        }
    }

    /// Selects the persisted format and fixed frame duration before the first
    /// frame starts flowing. If a saved combination is unavailable on a new
    /// lens/device, it publishes the closest supported choice instead of
    /// starting at one rate and switching under a visible preview.
    private func configureInitialVideoFormat(_ device: AVCaptureDevice) {
        let supportedRates = Self.availableFrameRates(for: device, resolution: videoResolution)
        let effectiveRate = supportedRates.contains(frameRate)
            ? frameRate
            : (supportedRates.contains(24) ? 24 : (supportedRates.first ?? frameRate))
        guard let format = Self.preferredFormat(for: device,
                                                 resolution: videoResolution,
                                                 frameRate: effectiveRate) else {
            publish(message: "\(videoResolution.rawValue) \(effectiveRate) fps is not available on this lens.")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(effectiveRate))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            guard effectiveRate != frameRate else { return }
            DispatchQueue.main.async {
                self.frameRate = effectiveRate
                UserDefaults.standard.set(effectiveRate, forKey: "incam.capture.frame-rate.v1")
            }
        } catch {
            publish(error)
        }
    }

    /// Applies the persisted codec while the session is already configuring.
    /// `readCapabilities` only reports this choice later; it does not mutate a
    /// live session during deferred startup.
    private func configurePreferredVideoCodec() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let supported = VideoCodec.allCases.filter {
            movieOutput.availableVideoCodecTypes.contains(Self.nativeCodec(for: $0))
        }
        let preferred = supported.contains(videoCodec)
            ? videoCodec
            : (supported.contains(.hevc) ? .hevc : (supported.first ?? .h264))
        guard supported.contains(preferred),
              movieOutput.supportedOutputSettingsKeys(for: connection).contains(AVVideoCodecKey) else { return }
        movieOutput.setOutputSettings([AVVideoCodecKey: Self.nativeCodec(for: preferred)], for: connection)
    }

    // Configures the real microphone input and AVAudioSession route after permission is granted.
    private func configureAudio() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        self.queue.async {
                            self.session.beginConfiguration()
                            self.configureAudio()
                            self.session.commitConfiguration()
                        }
                    } else { DispatchQueue.main.async { self.audioStatus = "Microphone access denied. Enable it in iPhone Settings." } }
                }
            } else { DispatchQueue.main.async { self.audioStatus = "Microphone access denied. Enable it in iPhone Settings." } }
            return
        }
        do {
            session.automaticallyConfiguresApplicationAudioSession = false
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
            let channels = min(audio.maximumInputNumberOfChannels, audioChannelMode.requestedChannelCount)
            if channels > 0 { try? audio.setPreferredInputNumberOfChannels(channels) }
            if audioOutputMode == .speaker { try? audio.overrideOutputAudioPort(.speaker) }
        } catch { publish(error); return }
        guard let microphone = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(audioInput) else { return }
        session.addInput(audioInput)
    }

    /// Enables Apple's responsive still pipeline only on formats that confirm
    /// support. It uses Zero Shutter Lag plus responsive/fast prioritization;
    /// automatic deferred delivery is intentionally not enabled because its
    /// full-resolution result is delivered through Photos, not this app's
    /// private gallery.
    // Enables only supported zero-shutter-lag, responsive and fast still-capture options.
    private func configurePhotoSpeedCapture(_ requested: PhotoSpeedMode) {
        let zeroShutterLagSupported = photoOutput.isZeroShutterLagSupported
        let wantsResponsive = requested == .responsive && zeroShutterLagSupported

        photoOutput.isZeroShutterLagEnabled = wantsResponsive
        let responsiveSupported = photoOutput.isResponsiveCaptureSupported
        let responsiveEnabled = wantsResponsive && responsiveSupported
        photoOutput.isResponsiveCaptureEnabled = responsiveEnabled

        let fastSupported = photoOutput.isFastCapturePrioritizationSupported
        photoOutput.isFastCapturePrioritizationEnabled = responsiveEnabled && fastSupported
        let effective: PhotoSpeedMode = responsiveEnabled ? .responsive : .standard

        DispatchQueue.main.async {
            self.zeroShutterLagSupported = zeroShutterLagSupported
            self.responsivePhotoCaptureSupported = zeroShutterLagSupported && responsiveSupported
            self.fastPhotoCaptureSupported = fastSupported
            self.photoSpeedMode = effective
            UserDefaults.standard.set(effective.rawValue, forKey: "incam.photo.speed.v1")
        }
    }

    /// Applies the saved, capability-checked preference whenever the active
    /// camera connection is rebuilt for a different lens or format.
    // Maps the selected app stabilization option to the active movie connection if valid.
    private func applyVideoStabilization() {
        guard let connection = movieOutput.connection(with: .video), let device = input?.device else { return }
        let requested = videoStabilization
        let native = Self.nativeStabilization(for: requested)
        let supported = requested == .off || (connection.isVideoStabilizationSupported && device.activeFormat.isVideoStabilizationModeSupported(native))
        let autoSupported = connection.isVideoStabilizationSupported && device.activeFormat.isVideoStabilizationModeSupported(.auto)
        let effective: VideoStabilization = supported ? requested : (autoSupported ? .auto : .off)
        connection.preferredVideoStabilizationMode = Self.nativeStabilization(for: effective)
        DispatchQueue.main.async {
            self.videoStabilization = effective
            UserDefaults.standard.set(effective.rawValue, forKey: "incam.capture.stabilization.v1")
        }
    }

    /// Session interruptions are expected when another camera client wins or
    /// iOS needs to reset media services. The visible message explains that
    /// state and the session resumes only while this screen is still active.
    // Registers for interruption and runtime-error notifications once for this controller lifetime.
    private func installSessionObservers() {
        let center = NotificationCenter.default
        sessionNotificationTokens = [
            center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil) { [weak self] _ in
                self?.performance.recordSessionRunning()
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] notification in
                self?.handleSessionInterrupted(notification)
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
                self?.resumeSessionIfNeeded(reason: "Camera connection restored.")
            },
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
                self?.handleSessionRuntimeError(notification)
            }
        ]
    }

    // Publishes an interrupted state when iOS temporarily takes the camera session away.
    private func handleSessionInterrupted(_ notification: Notification) {
        let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
        let suffix = reason.map { " (reason \($0.intValue))" } ?? ""
        DispatchQueue.main.async {
            self.health = .recovering("Camera paused by iPhone\(suffix). Waiting to resume.")
        }
        setSelectivePreviewPresentation(false)
    }

    // Reads an AVFoundation runtime failure and decides whether a safe session recovery is possible.
    private func handleSessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let reset = error?.code == .mediaServicesWereReset
        DispatchQueue.main.async {
            self.health = .recovering(reset ? "Camera service reset. Restoring the session…" : "Camera interrupted. Restoring the session…")
        }
        resumeSessionIfNeeded(reason: reset ? "Camera service restored." : "Camera recovered.")
    }

    // Restarts a configured session only when the viewfinder is still supposed to be running.
    private func resumeSessionIfNeeded(reason: String) {
        queue.async { [weak self] in
            guard let self, self.shouldRun, self.sessionConfigured else { return }
            if !self.session.isRunning { self.session.startRunning() }
            self.setSelectivePreviewPresentation(self.selectivePreviewEnabled)
            DispatchQueue.main.async { self.health = .ready }
        }
    }

    // Watches system pressure changes from the selected camera so the UI can report heat/pressure.
    private func observeDeviceHealth(_ device: AVCaptureDevice) {
        pressureObservation?.invalidate()
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            self?.handleSystemPressure(device.systemPressureState.level)
        }
    }

    // Converts Apple pressure levels into visible camera health and stops on shutdown-level pressure.
    private func handleSystemPressure(_ level: AVCaptureDevice.SystemPressureState.Level) {
        queue.async { [weak self] in
            guard let self else { return }
            let throttled: Bool
            let message: String?
            if level == .serious {
                throttled = true
                message = "Camera is warm — Camera Colors preview is reduced until it cools."
            } else if level == .critical {
                throttled = true
                message = "Camera is very warm — Camera Colors preview is reduced until it cools."
            } else if level == .shutdown {
                throttled = true
                message = "Camera paused while the iPhone cools."
            } else if level == .fair {
                throttled = false
                // `.fair` is a normal transitional pressure state—not an app
                // lock. Showing it as “warming up” made a working camera look
                // stuck forever, so only serious/critical pressure is visible.
                message = nil
            } else if level == .nominal {
                throttled = false
                message = nil
            } else {
                throttled = true
                message = "Camera is managing device temperature."
            }

            if self.pressureThrottledPreview != throttled {
                self.pressureThrottledPreview = throttled
                self.setSelectivePreviewFrameRate(throttled ? 15 : 30)
            }
            DispatchQueue.main.async {
                self.health = message.map(CameraHealth.pressure) ?? .ready
            }
            if level == .shutdown, self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Re-activates the already-authorized recording route only when the
    /// camera screen returns. It never creates a background audio task.
    // Reactivates an already-authorized microphone route when a configured camera session resumes.
    private func activateAudioSession() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
        } catch { publish(error) }
    }

    // Starts the intentionally low-frequency five-Hz meter timer for real microphone channels.
    private func startAudioMetering() {
        guard audioMeterTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Five updates per second keeps a usable L/R meter but avoids turning
        // the whole camera screen into a continuous layout workload.
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let audio = AVAudioSession.sharedInstance()
            let inputs = (audio.availableInputs ?? []).map { AudioInputOption(id: $0.uid, name: $0.portName) }
            let selected = audio.currentRoute.inputs.first?.uid ?? ""
            let output = audio.currentRoute.outputs.map(\.portName).joined(separator: ", ")
            let channels = self.movieOutput.connection(with: .audio)?.audioChannels ?? []
            let levels = channels.map { min(0, max(-60, $0.averagePowerLevel.isFinite ? $0.averagePowerLevel : -60)) }
            let gain = audio.inputGain
            let supported = audio.isInputGainSettable
            DispatchQueue.main.async {
                self.audioInputs = inputs
                self.audioInputID = selected
                self.audioOutputName = output.isEmpty ? "Unavailable" : output
                self.audioGain = gain
                self.audioGainSupported = supported
                self.audioLevels = levels
                if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
                    self.audioStatus = channels.isEmpty ? "No active microphone signal" : (channels.count >= 2 ? "Stereo input · dBFS" : "Mono input · R unavailable")
                }
            }
        }
        audioMeterTimer = timer
        timer.resume()
    }

    // Selects a supported audio route unless a recording makes route changes unsafe.
    func selectAudioInput(_ uid: String) {
        guard !isRecording else { return }
        queue.async { [weak self] in
            let audio = AVAudioSession.sharedInstance()
            guard let input = audio.availableInputs?.first(where: { $0.uid == uid }) else { return }
            do { try audio.setPreferredInput(input) } catch { self?.publish(error) }
        }
    }

    // Applies microphone gain only on inputs where iOS allows gain adjustment.
    func setAudioGain(_ gain: Float) {
        queue.async { [weak self] in
            let audio = AVAudioSession.sharedInstance()
            guard audio.isInputGainSettable else { return }
            do { try audio.setInputGain(min(1, max(0, gain))) } catch { self?.publish(error) }
        }
    }

    // Requests mono or stereo channel count from the active audio session and persists it.
    func setAudioChannelMode(_ mode: AudioChannelMode) {
        guard !isRecording else { return }
        audioChannelMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "incam.audio.channel-mode.v1")
        queue.async { [weak self] in
            guard let self else { return }
            let audio = AVAudioSession.sharedInstance()
            let count = min(audio.maximumInputNumberOfChannels, mode.requestedChannelCount)
            guard count > 0 else { return }
            do { try audio.setPreferredInputNumberOfChannels(count) }
            catch { self.publish(error) }
        }
    }

    // Chooses the system or speaker output route while retaining the saved preference.
    func setAudioOutputMode(_ mode: AudioOutputMode) {
        audioOutputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "incam.audio.output-mode.v1")
        queue.async { [weak self] in
            do {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(mode == .speaker ? .speaker : .none)
            } catch { self?.publish(error) }
        }
    }

    // Sanitizes and persists the user-facing folder component used for private media storage.
    func setRecordingFolderName(_ value: String) {
        let cleaned = Self.cleanedFolderName(value)
        recordingFolderName = cleaned
        UserDefaults.standard.set(cleaned, forKey: "incam.media.folder.v1")
    }

    // Sanitizes and persists the file-name prefix used for the next recordings.
    func setRecordingPrefix(_ value: String) {
        let cleaned = Self.cleanedPrefix(value)
        recordingPrefix = cleaned
        UserDefaults.standard.set(cleaned, forKey: "incam.media.prefix.v1")
    }

    // Persists whether new media uses a sequence-based or date-based file name.
    func setRecordingNamingMode(_ mode: RecordingNamingMode) {
        recordingNamingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "incam.media.naming.v1")
    }

    private func readCapabilities(_ device: AVCaptureDevice, resolution requestedResolution: VideoResolution? = nil) {
        // CAPABILITY DISCOVERY: the UI lists only combinations this physical
        // lens supports. Profiling may justify caching this per lens/resolution,
        // but removing it would let the UI offer formats that cannot be used.
        let format = device.activeFormat
        let activeLens = Self.lensOption(device)
        // The active format may be 4K/24 even though another format on this
        // exact lens supports 4K/60. List rates for the selected resolution,
        // then select the matching active format when the person chooses it.
        let resolution = requestedResolution ?? videoResolution
        let rates = Self.availableFrameRates(for: device, resolution: resolution)
        let photoFormats = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? ["HEIF", "JPEG"] : ["JPEG"]
        let supportedResolutions = VideoResolution.allCases.filter {
            self.session.canSetSessionPreset(Self.sessionPreset(for: $0))
        }.filter { AppFeatureAvailability.fourKCapture || $0 != .p4K }
        let supportedCodecs = VideoCodec.allCases.filter {
            self.movieOutput.availableVideoCodecTypes.contains(Self.nativeCodec(for: $0))
        }
        let preferredCodec: VideoCodec = supportedCodecs.contains(videoCodec)
            ? videoCodec
            : (supportedCodecs.contains(.hevc) ? .hevc : (supportedCodecs.first ?? .h264))
        // The codec was applied during the initial configuration transaction.
        // This delayed capability pass is intentionally read/publish-only so
        // it cannot reconfigure the just-visible viewfinder.
        let rawSupported = !photoOutput.availableRawPhotoPixelFormatTypes.isEmpty
        let hdrSupported = format.isVideoHDRSupported
        let stabilizations: [VideoStabilization] = {
            guard let connection = movieOutput.connection(with: .video) else { return [.off] }
            return VideoStabilization.allCases.filter {
                $0 == .off || (connection.isVideoStabilizationSupported && format.isVideoStabilizationModeSupported(Self.nativeStabilization(for: $0)))
            }
        }()
        let dimensions = photoOutput.maxPhotoDimensions
        let megapixels = max(1, Int((Double(dimensions.width) * Double(dimensions.height) / 1_000_000).rounded()))
        let value = CameraCapabilities(
            minISO: format.minISO,
            maxISO: format.maxISO,
            minExposureSeconds: max(1.0 / 100_000, CMTimeGetSeconds(format.minExposureDuration)),
            // Do not invent a two-second cap. The camera format decides which
            // of the approved 1–30 second values are actually usable.
            maxExposureSeconds: min(30, CMTimeGetSeconds(format.maxExposureDuration)),
            minZoom: device.minAvailableVideoZoomFactor,
            maxZoom: min(device.maxAvailableVideoZoomFactor, 10),
            frameRates: rates.isEmpty ? [24] : rates,
            photoFormats: photoFormats,
            resolutions: ["\(megapixels) MP"])
        DispatchQueue.main.async {
            self.capabilities = value
            self.aperture = device.lensAperture
            self.focusAuto = device.focusMode != .locked
            self.focusPosition = device.lensPosition
            if let index = self.lenses.firstIndex(where: { $0.id == activeLens.id }) { self.lenses[index] = activeLens }
            if !photoFormats.contains(self.photoFormat) { self.photoFormat = photoFormats[0] }
            self.availableVideoResolutions = supportedResolutions
            if !supportedResolutions.contains(self.videoResolution) {
                // Prefer the intended 1080p mode, then choose the only viable
                // lower resolution on hardware that cannot offer it.
                self.videoResolution = supportedResolutions.contains(.p1080) ? .p1080 : (supportedResolutions.first ?? .p720)
            }
            self.availableVideoCodecs = supportedCodecs
            self.videoCodec = preferredCodec
            self.rawPhotoSupported = rawSupported
            self.videoHDRSupported = hdrSupported
            self.videoHDREnabled = device.isVideoHDREnabled
            self.availableVideoStabilizations = stabilizations.isEmpty ? [.off] : stabilizations
            if !self.availableVideoStabilizations.contains(self.videoStabilization) {
                self.videoStabilization = self.availableVideoStabilizations.contains(.auto) ? .auto : .off
            }
            // Preserve an explicit choice across camera capability refreshes.
            // A fresh session starts at 24 fps where the lens supports it.
            if !rates.contains(self.frameRate) {
                self.frameRate = rates.contains(24) ? 24 : (rates.first ?? 24)
                UserDefaults.standard.set(self.frameRate, forKey: "incam.capture.frame-rate.v1")
            }
            self.zoom = device.videoZoomFactor
            if self.exposureAuto {
                self.iso = device.iso
                self.exposureSeconds = CMTimeGetSeconds(device.exposureDuration)
            }
            if self.whiteBalanceAuto {
                let values = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                self.temperature = values.temperature
                self.tint = values.tint
            }
        }
    }

    // Creates a photo request using the active still format and passes completion to AVCapture delegate methods.
    private func capturePhoto() {
        let requestedFormat = photoFormat
        let requestedSpeed = photoSpeedMode
        DispatchQueue.main.async { self.isCapturingPhoto = true }
        queue.async { [weak self] in
            guard let self, self.sessionConfigured else {
                DispatchQueue.main.async { self?.isCapturingPhoto = false }
                return
            }
            let codec: AVVideoCodecType = requestedFormat == "HEIF" && self.photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
            self.rotate(self.photoOutput.connection(with: .video))
            settings.photoQualityPrioritization = requestedSpeed == .responsive ? .speed : .quality
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // Starts a movie file recording after applying output orientation and generating a unique destination URL.
    private func startRecording() {
        queue.async { [weak self] in
            guard let self, self.sessionConfigured, !self.movieOutput.isRecording else { return }
            self.rotate(self.movieOutput.connection(with: .video))
            self.recipeLock.lock()
            self.recordedRecipe = self.cameraColorRecipe
            self.recordedOutputFramingAspect = self.outputFramingAspect
            self.recipeLock.unlock()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
            DispatchQueue.main.async {
                self.isRecording = true
                self.recordStartedAt = Date()
                self.startTimer()
            }
        }
    }

    // Asks AVFoundation to finish the current movie; final save happens in the delegate callback.
    private func stopRecording() {
        queue.async { [weak self] in self?.movieOutput.stopRecording() }
    }

    /// The main preview and optional Metal Color Mix preview are separate
    /// AVFoundation connections. The viewfinder owns its front-camera
    /// presentation transform, so this data connection stays unmirrored.
    // Applies the current interface orientation to a supported capture connection.
    private func rotate(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoRotationAngleSupported(captureRotation) {
            connection.videoRotationAngle = captureRotation
        }
    }

    // Locks the device and applies the currently selected manual ISO/shutter values together.
    private func applyExposure() {
        queue.async { [weak self] in
            guard let self, let device = self.input?.device, device.isExposureModeSupported(.custom) else { return }
            do {
                try device.lockForConfiguration()
                let seconds = min(CMTimeGetSeconds(device.activeFormat.maxExposureDuration),
                                  max(CMTimeGetSeconds(device.activeFormat.minExposureDuration), self.exposureSeconds))
                let duration = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
                let clampedISO = min(device.activeFormat.maxISO, max(device.activeFormat.minISO, self.iso))
                device.setExposureTargetBias(0, completionHandler: nil)
                device.setExposureModeCustom(duration: duration, iso: clampedISO)
                device.unlockForConfiguration()
            } catch { self.publish(error) }
        }
    }

    // Converts the selected temperature/tint into device gains and locks them on the active lens.
    private func applyWhiteBalance() {
        queue.async { [weak self] in
            guard let self, let device = self.input?.device,
                  device.isWhiteBalanceModeSupported(.locked) else { return }
            do {
                try device.lockForConfiguration()
                var gains = device.deviceWhiteBalanceGains(for: .init(
                    temperature: self.temperature, tint: self.tint))
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(maxGain, max(1, gains.redGain))
                gains.greenGain = min(maxGain, max(1, gains.greenGain))
                gains.blueGain = min(maxGain, max(1, gains.blueGain))
                device.setWhiteBalanceModeLocked(with: gains)
                device.unlockForConfiguration()
            } catch { self.publish(error) }
        }
    }

    // Starts the recording elapsed-time publisher on the main queue.
    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let recordStartedAt else { return }
            elapsed = Date().timeIntervalSince(recordStartedAt)
        }
    }

    // Cancels the elapsed-time publisher and resets the record timer display.
    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
        recordStartedAt = nil
    }

    // Starts gravity updates for the on-screen level indicator when level monitoring is enabled.
    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: levelMotionQueue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            // Project gravity onto the display plane. Unlike attitude.roll,
            // this remains well-behaved when the phone approaches vertical.
            let rawRollRadians = atan2(-motion.gravity.x, -motion.gravity.y)

            // Filter at sensor cadence, but do not ask SwiftUI to redraw the
            // full camera screen sixty times per second. A 30 Hz indicator is
            // visually smooth and leaves headroom for touch and capture.
            let alpha = 0.15
            self.filteredLevelRollRadians = alpha * rawRollRadians
                + (1 - alpha) * self.filteredLevelRollRadians
            var deviation = self.filteredLevelRollRadians
                .truncatingRemainder(dividingBy: .pi / 2)
            if deviation > .pi / 4 { deviation -= .pi / 2 }
            if deviation < -.pi / 4 { deviation += .pi / 2 }
            let deviationDegrees = abs(deviation * 180 / .pi)
            let leveled = self.levelCenteredOnMotionQueue
                ? deviationDegrees <= 1.5
                : deviationDegrees <= 1.0
            self.levelCenteredOnMotionQueue = leveled
            let displayRadians = leveled
                ? self.filteredLevelRollRadians - deviation
                : self.filteredLevelRollRadians
            let now = Date()
            guard now.timeIntervalSince(self.lastLevelUIPublish) >= (1.0 / 30.0) else { return }
            self.lastLevelUIPublish = now
            let displayDegrees = displayRadians * 180 / .pi
            DispatchQueue.main.async { [weak self] in
                guard let self, self.levelMonitoringEnabled else { return }
                self.levelIsCentered = leveled
                self.levelRoll = displayDegrees
                self.levelPitch = 0
            }
        }
    }

    // Stores display orientation so gravity axes map correctly to the visible level indicator.
    func setLevelInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard orientation != .unknown else { return }
        levelInterfaceOrientation = orientation
    }

    /// Motion data is useful only while the visible Level tool is enabled.
    /// Keeping it off otherwise prevents a 20 Hz SwiftUI refresh of the
    /// entire live camera screen and keeps ordinary controls responsive.
    // Starts or stops motion sensing according to the level-overlay preference.
    func setLevelMonitoringEnabled(_ enabled: Bool) {
        levelMonitoringEnabled = enabled
        if enabled {
            startMotion()
        } else {
            motion.stopDeviceMotionUpdates()
            filteredLevelRollRadians = 0
            levelCenteredOnMotionQueue = false
            lastLevelUIPublish = .distantPast
            levelRoll = 0
            levelPitch = 0
            levelIsCentered = false
        }
    }

    // Maps the app resolution choice to the closest AVCapture session preset.
    private static func sessionPreset(for resolution: VideoResolution) -> AVCaptureSession.Preset {
        switch resolution {
        case .p720: return .hd1280x720
        case .p1080: return .hd1920x1080
        case .p4K: return .hd4K3840x2160
        }
    }

    // Supplies nominal pixel dimensions used when selecting a compatible active format.
    private static func targetDimensions(for resolution: VideoResolution) -> (width: Int32, height: Int32) {
        switch resolution {
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        case .p4K: return (3840, 2160)
        }
    }

    // Tests whether a device format can satisfy a requested resolution and frame rate combination.
    private static func supports(_ format: AVCaptureDevice.Format,
                                 resolution: VideoResolution,
                                 frameRate: Int) -> Bool {
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let target = targetDimensions(for: resolution)
        guard dimensions.width >= target.width, dimensions.height >= target.height else { return false }
        return format.videoSupportedFrameRateRanges.contains {
            Double(frameRate) >= $0.minFrameRate && Double(frameRate) <= $0.maxFrameRate
        }
    }

    // Enumerates frame rates supported by formats matching a requested resolution on one lens.
    private static func availableFrameRates(for device: AVCaptureDevice,
                                            resolution: VideoResolution) -> [Int] {
        [24, 25, 30, 50, 60, 120].filter { rate in
            device.formats.contains { supports($0, resolution: resolution, frameRate: rate) }
        }
    }

    // Selects the best matching physical format for a requested resolution/FPS pair.
    private static func preferredFormat(for device: AVCaptureDevice,
                                        resolution: VideoResolution,
                                        frameRate: Int) -> AVCaptureDevice.Format? {
        let target = targetDimensions(for: resolution)
        return device.formats
            .filter { supports($0, resolution: resolution, frameRate: frameRate) }
            .sorted { lhs, rhs in
                let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let leftDistance = abs(Int(left.width - target.width)) + abs(Int(left.height - target.height))
                let rightDistance = abs(Int(right.width - target.width)) + abs(Int(right.height - target.height))
                return leftDistance < rightDistance
            }
            .first
    }

    // Translates the app codec enum into AVFoundation's movie-output codec type.
    private static func nativeCodec(for codec: VideoCodec) -> AVVideoCodecType {
        switch codec {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422LT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        }
    }

    // Translates the app stabilization enum into AVFoundation's connection mode.
    private static func nativeStabilization(for value: VideoStabilization) -> AVCaptureVideoStabilizationMode {
        switch value {
        case .off: return .off
        case .auto: return .auto
        case .standard: return .standard
        case .cinematic: return .cinematic
        }
    }

    // Converts an AVFoundation stabilization mode back into the app's display enum.
    private static func stabilization(for value: AVCaptureVideoStabilizationMode) -> VideoStabilization {
        switch value {
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .auto: return .auto
        default: return .off
        }
    }

    /// Keeps an app-private copy before offering the same capture to Photos.
    /// The local copy powers InCam's gallery without read access to Photos.
    // Requests Photos-library save and optionally keeps InCam's private gallery copy of a movie file.
    private func saveToPhotos(_ url: URL, persistPrivateCopy: Bool = true) {
        let localURL = persistPrivateCopy ? persistMovie(url) : url
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                if persistPrivateCopy || localURL != url { try? FileManager.default.removeItem(at: url) }
                return
            }
            var identifier: String?
            PHPhotoLibrary.shared().performChanges {
                identifier = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: localURL)?.placeholderForCreatedAsset?.localIdentifier
            } completionHandler: { success, _ in
                // The Photos asset identifier is intentionally not used by
                // InCam's gallery: it would require read access to the user's
                // complete library. The private copy remains available here.
                _ = identifier
                if persistPrivateCopy || localURL != url { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    // Writes a captured photo to Photos and InCam's private media list when permitted.
    private func savePhoto(_ data: Data) {
        persistPhoto(data)
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            } completionHandler: { _, _ in }
        }
    }

    // Resolves and creates the app-private media directory, optionally within a user-named folder.
    private static func privateMediaDirectory(folder: String = "") -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InCam Media", isDirectory: true)
        let directory = folder.isEmpty ? root : root.appendingPathComponent(cleanedFolderName(folder), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult private func persistMovie(_ sourceURL: URL) -> URL {
        let filename = nextRecordingFilename(extension: sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension)
        let folder = recordingNamingMode == .date ? Self.todayFolderName() : recordingFolderName
        let relativeFilename = folder + "/" + filename
        let destination = Self.privateMediaDirectory(folder: folder).appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            rememberPrivateMedia(filename: relativeFilename, kind: .video)
            return destination
        } catch {
            publish(message: "InCam could not keep a private copy of this video.")
            return sourceURL
        }
    }

    // Saves photo bytes into private app storage and records a gallery metadata entry.
    private func persistPhoto(_ data: Data) {
        let filename = nextRecordingFilename(extension: "jpg")
        let folder = recordingNamingMode == .date ? Self.todayFolderName() : recordingFolderName
        let relativeFilename = folder + "/" + filename
        let destination = Self.privateMediaDirectory(folder: folder).appendingPathComponent(filename)
        do {
            try data.write(to: destination, options: .atomic)
            rememberPrivateMedia(filename: relativeFilename, kind: .photo)
        } catch { publish(message: "InCam could not keep a private copy of this photo.") }
    }

    // Builds the next safe video/photo filename from prefix, date/sequence mode and file extension.
    private func nextRecordingFilename(extension fileExtension: String) -> String {
        let folder = recordingNamingMode == .date ? Self.todayFolderName() : recordingFolderName
        let directory = Self.privateMediaDirectory(folder: folder)
        let stem: String = recordingNamingMode == .date ? "\(Self.todayFolderName())" : "\(recordingPrefix)_\(folder)"
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let next = (1...9_999).first { index in
            !existing.contains("\(stem)_\(String(format: "%04d", index)).\(fileExtension)")
        } ?? 9_999
        return "\(stem)_\(String(format: "%04d", next)).\(fileExtension)"
    }

    // Formats today's date in the stable YYYY-MM-DD folder naming convention.
    private static func todayFolderName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // Restricts a folder label to the supported short, filesystem-safe character set.
    private static func cleanedFolderName(_ value: String) -> String {
        let allowed = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return String((allowed.isEmpty ? "ENES" : allowed).prefix(5))
    }

    // Restricts a recording prefix to safe filename characters before persistence.
    private static func cleanedPrefix(_ value: String) -> String {
        let allowed = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return String((allowed.isEmpty ? "INCAM" : allowed).prefix(12))
    }

    /// Gallery history names only files produced by this app. It does not hold
    /// Photos identifiers or query the user's existing camera roll.
    // Appends one saved item to the lightweight private-gallery metadata store.
    private func rememberPrivateMedia(filename: String, kind: InCamSavedMedia.Kind) {
        let defaults = UserDefaults.standard
        var media = (try? JSONDecoder().decode([InCamSavedMedia].self,
                                                from: defaults.data(forKey: Self.savedMediaKey) ?? Data())) ?? []
        let item = InCamSavedMedia(id: UUID(), filename: filename, kind: kind, createdAt: Date())
        media.insert(item, at: 0)
        defaults.set(try? JSONEncoder().encode(Array(media.prefix(500))), forKey: Self.savedMediaKey)
    }

    // Returns the currently selected Custom Color recipe or a neutral fallback.
    private func currentRecipe() -> CameraColorRecipe {
        recipeLock.lock()
        defer { recipeLock.unlock() }
        return cameraColorRecipe
    }

    // Returns the selected composition aspect only when output framing has been requested.
    private func currentOutputFramingAspect() -> CGFloat? {
        recipeLock.lock()
        defer { recipeLock.unlock() }
        return outputFramingAspect
    }

    /// Returns a centered crop with the requested width / height. The source
    /// remains otherwise untouched; this is the exact guide ratio chosen by
    /// the person, never an arbitrary screen rectangle.
    // Calculates a centered crop rectangle with a requested aspect ratio inside an image extent.
    private static func cropRect(for extent: CGRect, aspect: CGFloat) -> CGRect {
        guard extent.width > 0, extent.height > 0, aspect.isFinite, aspect > 0 else { return extent }
        let sourceAspect = extent.width / extent.height
        if sourceAspect > aspect {
            let width = extent.height * aspect
            return CGRect(x: extent.midX - width / 2, y: extent.minY, width: width, height: extent.height).integral
        }
        let height = extent.width / aspect
        return CGRect(x: extent.minX, y: extent.midY - height / 2, width: extent.width, height: height).integral
    }

    /// Applies Camera Colors to a completed movie, preserving its audio track.
    /// File output has no filtering hook, so this export is the reliable way to
    /// make the saved clip match the filtered live preview.
    // Exports a processed/cropped movie only when the active recipe or output framing requires it.
    private func saveProcessedMovieIfNeeded(_ sourceURL: URL, recipe: CameraColorRecipe, outputAspect: CGFloat?) {
        guard recipe.hasVisibleAdjustments || outputAspect != nil else {
            saveToPhotos(sourceURL)
            return
        }
        // Put the completed camera file in InCam's gallery immediately. The
        // optional color export can take longer, but it must not make a video
        // look as though it was lost when the person opens Gallery.
        let privateGalleryURL = persistMovie(sourceURL)
        let asset = AVURLAsset(url: sourceURL)
        let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let source = request.sourceImage
            let cropped = outputAspect.map { source.cropped(to: Self.cropRect(for: source.extent, aspect: $0)) } ?? source
            let rendered = recipe.hasVisibleAdjustments
                ? RecipeRenderer.render(cropped.clampedToExtent(), recipe: recipe).cropped(to: cropped.extent)
                : cropped
            request.finish(with: rendered, context: nil)
        })
        if let outputAspect {
            composition.renderSize = Self.cropRect(
                for: CGRect(origin: .zero, size: composition.renderSize),
                aspect: outputAspect
            ).size
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            publish(message: "Camera Colors could not prepare this video for saving.")
            saveToPhotos(sourceURL)
            return
        }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        export.outputURL = outputURL
        export.outputFileType = .mov
        export.videoComposition = composition
        export.exportAsynchronously { [weak self] in
            guard let self else { return }
            if export.status == .completed {
                // Replace the provisional private copy in place. Gallery gets
                // an immediate clip, then the same item becomes the rendered
                // Clarity/Saturation/Contrast/Camera Colors result.
                if privateGalleryURL != sourceURL {
                    try? FileManager.default.removeItem(at: privateGalleryURL)
                    do {
                        try FileManager.default.copyItem(at: outputURL, to: privateGalleryURL)
                    } catch {
                        self.publish(message: "Camera Colors exported, but InCam could not update the Gallery copy.")
                    }
                }
                try? FileManager.default.removeItem(at: sourceURL)
                // Gallery already owns the original private copy. The
                // processed temporary file goes only to the optional Photos
                // copy, avoiding a duplicate Gallery item.
                self.saveToPhotos(outputURL, persistPrivateCopy: false)
            } else {
                try? FileManager.default.removeItem(at: outputURL)
                self.publish(message: "Camera Colors could not finish the saved video. The unadjusted clip was saved instead.")
                // The gallery already has this source clip unless its first
                // copy failed, so avoid adding a duplicate on export failure.
                self.saveToPhotos(sourceURL, persistPrivateCopy: privateGalleryURL == sourceURL)
            }
        }
    }

    // Converts an Error into the user-visible message path used by camera operations.
    private func publish(_ error: Error) { publish(message: error.localizedDescription) }
    // Publishes a camera error on Main so SwiftUI never receives background-thread mutations.
    private func publish(message: String) {
        DispatchQueue.main.async { self.lastError = message }
    }
}

/// Signposts only measured capture-pipeline events. They are intentionally
/// private to avoid adding a frequent `@Published` update to CameraScreen.
/// Inspect the `InCam.CameraPerformance` category in Instruments / Console.
/// Preview readiness is the preview layer's rendering signal; it is not an
/// estimate of exposure or autofocus settling time.
private final class CameraPerformanceInstrumentation {
    private struct Startup {
        let generation: Int
        let requestedAt: TimeInterval
        var sessionRunningAt: TimeInterval?
        var previewReadyAt: TimeInterval?
        var firstHistogramResultAt: TimeInterval?
    }

    private let lock = NSLock()
    private let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "app.incam",
        category: "CameraPerformance"
    )
    private var startup: Startup?
    private var nextGeneration = 0
    private var droppedAnalysisFrames = 0

    static func monotonicTime() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    func recordStartupRequested() {
        let now = Self.monotonicTime()
        lock.lock()
        nextGeneration &+= 1
        startup = Startup(generation: nextGeneration, requestedAt: now)
        droppedAnalysisFrames = 0
        let generation = nextGeneration
        lock.unlock()
        os_signpost(.event, log: log, name: "Startup Requested", "generation=%{public}ld", generation)
    }

    func recordSessionRunning() {
        let now = Self.monotonicTime()
        lock.lock()
        guard var startup, startup.sessionRunningAt == nil else {
            lock.unlock()
            return
        }
        startup.sessionRunningAt = now
        self.startup = startup
        let milliseconds = (now - startup.requestedAt) * 1_000
        lock.unlock()
        os_signpost(.event, log: log, name: "Session Running", "startup_ms=%{public}.2f", milliseconds)
    }

    func recordPreviewLayerReady() {
        let now = Self.monotonicTime()
        lock.lock()
        guard var startup, startup.previewReadyAt == nil else {
            lock.unlock()
            return
        }
        startup.previewReadyAt = now
        self.startup = startup
        let milliseconds = (now - startup.requestedAt) * 1_000
        lock.unlock()
        os_signpost(.event, log: log, name: "Preview Layer Ready", "startup_ms=%{public}.2f", milliseconds)
    }

    func recordFirstHistogramResult() {
        let now = Self.monotonicTime()
        lock.lock()
        guard var startup, startup.firstHistogramResultAt == nil else {
            lock.unlock()
            return
        }
        startup.firstHistogramResultAt = now
        self.startup = startup
        let milliseconds = (now - startup.requestedAt) * 1_000
        lock.unlock()
        os_signpost(.event, log: log, name: "First Histogram Result", "startup_ms=%{public}.2f", milliseconds)
    }

    func recordScopeAnalysisDuration(mode: SceneScopeMode, milliseconds: TimeInterval) {
        os_signpost(.event, log: log, name: "Scope Analysis", "mode=%{public}s duration_ms=%{public}.2f", mode.rawValue, milliseconds)
    }

    func recordAnalysisFrameDrop(_ sampleBuffer: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        let attachment = (attachments as? [[CFString: Any]])?.first
        let reason = attachment?[kCMSampleBufferAttachmentKey_DroppedFrameReason] as? String
        let name: String
        switch reason {
        case String(kCMSampleBufferDroppedFrameReason_FrameWasLate):
            name = "late"
        case String(kCMSampleBufferDroppedFrameReason_OutOfBuffers):
            name = "out_of_buffers"
        case String(kCMSampleBufferDroppedFrameReason_Discontinuity):
            name = "discontinuity"
        default:
            name = "unknown"
        }
        lock.lock()
        droppedAnalysisFrames &+= 1
        let count = droppedAnalysisFrames
        lock.unlock()
        os_signpost(.event, log: log, name: "Analysis Frame Dropped", "count=%{public}ld reason=%{public}s", count, name)
    }
}

// MARK: - On-demand selective Color Mix preview

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    // Receives live video frames for the optional color renderer and/or scope.
    // Neither path is attached during ordinary camera startup.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === selectivePreviewOutput else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        if sceneScopeMode != .off {
            updateSceneScope(pixelBuffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        selectivePreviewSinkLock.lock()
        let sink = selectivePreviewSink
        selectivePreviewSinkLock.unlock()
        if focusPeakingEnabled {
            // The Metal view retains only this newest IOSurface-backed frame.
            // No sampled points cross into SwiftUI's rendering system.
            sink?.submitFocusPeakingFrame(pixelBuffer)
        }

        guard selectivePreviewEnabled else { return }
        let recipe = currentRecipe()
        guard recipe.hasVisibleAdjustments else { return }
        // The sink receives the capture texture immediately. It keeps only
        // the newest frame and presents it through an MTKView at display rate,
        // so slow draws are dropped instead of forming a delayed frame queue.
        sink?.submitSelectiveColorFrame(pixelBuffer, recipe: recipe)
    }

    /// Measured by AVFoundation on the same serial delegate queue as delivered
    /// frames. A nonzero count is evidence of an analysis path that cannot
    /// keep pace; it is not inferred from UI animation or user perception.
    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === selectivePreviewOutput else { return }
        performance.recordAnalysisFrameDrop(sampleBuffer)
    }

    /// Samples a 48×40 BGRA grid at most ten times per second. That is enough
    /// for a responsive RGB analyser while avoiding full-resolution CPU work
    /// or a frame queue that would make camera capture feel delayed.
    private func updateSceneScope(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        if lastSceneScopeTimestamp.isValid,
           CMTimeGetSeconds(CMTimeSubtract(timestamp, lastSceneScopeTimestamp)) < 0.10 {
            return
        }
        lastSceneScopeTimestamp = timestamp

        let mode = sceneScopeMode
        let analysisStartedAt = CameraPerformanceInstrumentation.monotonicTime()
        defer {
            performance.recordScopeAnalysisDuration(
                mode: mode,
                milliseconds: (CameraPerformanceInstrumentation.monotonicTime() - analysisStartedAt) * 1_000
            )
        }
        let columns = 48
        let rows = 40
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytes = address.assumingMemoryBound(to: UInt8.self)
        let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var waveform = [Float](repeating: 0, count: columns)
        var redWaveform = [Float](repeating: 0, count: columns)
        var greenWaveform = [Float](repeating: 0, count: columns)
        var blueWaveform = [Float](repeating: 0, count: columns)
        var histogram = [Int](repeating: 0, count: columns)
        var redHistogram = [Int](repeating: 0, count: columns)
        var greenHistogram = [Int](repeating: 0, count: columns)
        var blueHistogram = [Int](repeating: 0, count: columns)
        for column in 0..<columns {
            let x = min(width - 1, (column * width) / columns)
            var total: Float = 0
            var redTotal: Float = 0
            var greenTotal: Float = 0
            var blueTotal: Float = 0
            for row in 0..<rows {
                let y = min(height - 1, (row * height) / rows)
                let pixel = bytes.advanced(by: y * rowStride + x * 4)
                // AVCaptureVideoDataOutput delivers BGRA. Keep the native
                // channels for the RGB monitor and derive Rec. 709 luma for
                // the compatibility summary used by existing callers.
                let blue = Float(pixel[0]) / 255
                let green = Float(pixel[1]) / 255
                let red = Float(pixel[2]) / 255
                let luma = 0.0722 * blue + 0.7152 * green + 0.2126 * red
                total += luma
                redTotal += red
                greenTotal += green
                blueTotal += blue
                histogram[min(columns - 1, max(0, Int(luma * Float(columns - 1))))] += 1
                redHistogram[min(columns - 1, max(0, Int(red * Float(columns - 1))))] += 1
                greenHistogram[min(columns - 1, max(0, Int(green * Float(columns - 1))))] += 1
                blueHistogram[min(columns - 1, max(0, Int(blue * Float(columns - 1))))] += 1
            }
            waveform[column] = total / Float(rows)
            redWaveform[column] = redTotal / Float(rows)
            greenWaveform[column] = greenTotal / Float(rows)
            blueWaveform[column] = blueTotal / Float(rows)
        }

        let samples: [Float]
        let redSamples: [Float]
        let greenSamples: [Float]
        let blueSamples: [Float]
        if mode == .histogram {
            let peak = max(1, histogram.max() ?? 1)
            samples = histogram.map { Float($0) / Float(peak) }
            let redPeak = max(1, redHistogram.max() ?? 1)
            let greenPeak = max(1, greenHistogram.max() ?? 1)
            let bluePeak = max(1, blueHistogram.max() ?? 1)
            redSamples = redHistogram.map { Float($0) / Float(redPeak) }
            greenSamples = greenHistogram.map { Float($0) / Float(greenPeak) }
            blueSamples = blueHistogram.map { Float($0) / Float(bluePeak) }
        } else {
            samples = waveform
            redSamples = redWaveform
            greenSamples = greenWaveform
            blueSamples = blueWaveform
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sceneScopeMode == mode else { return }
            self.sceneScopeSamples = samples
            self.sceneScopeRedSamples = redSamples
            self.sceneScopeGreenSamples = greenSamples
            self.sceneScopeBlueSamples = blueSamples
            if mode == .histogram {
                self.performance.recordFirstHistogramResult()
            }
        }
    }

}

extension CameraController: AVCapturePhotoCaptureDelegate {
    // Handles photo completion, updates capture state and starts durable save work.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        DispatchQueue.main.async { self.isCapturingPhoto = false }
        if let error { publish(error); return }
        guard let data = photo.fileDataRepresentation() else { return }
        let recipe = currentRecipe()
        let outputAspect = currentOutputFramingAspect()
        guard (recipe.hasVisibleAdjustments || outputAspect != nil), let image = CIImage(data: data) else {
            savePhoto(data)
            return
        }
        let cropped = outputAspect.map { image.cropped(to: Self.cropRect(for: image.extent, aspect: $0)) } ?? image
        let rendered = recipe.hasVisibleAdjustments ? RecipeRenderer.render(cropped, recipe: recipe) : cropped
        guard let adjusted = RecipeRenderer.context.jpegRepresentation(of: rendered, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            savePhoto(data)
            return
        }
        savePhoto(adjusted)
    }
}

extension CameraController: AVCaptureFileOutputRecordingDelegate {
    // Handles movie completion, resets recording state and sends the finished file through save/export.
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.stopTimer()
        }
        if let error { publish(error); return }
        recipeLock.lock()
        let recipe = recordedRecipe
        let outputAspect = recordedOutputFramingAspect
        recipeLock.unlock()
        saveProcessedMovieIfNeeded(outputFileURL, recipe: recipe, outputAspect: outputAspect)
    }
}

private enum CameraFailure: LocalizedError {
    case configuration
    var errorDescription: String? { "The camera could not be configured for capture." }
}
