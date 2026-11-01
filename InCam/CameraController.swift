import AVFoundation
import CoreImage
import CoreMotion
import Photos
import SwiftUI

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
    /// InCam starts with the highest common capture choice. The actual camera
    /// still reports its supported formats and falls back safely when needed.
    @Published private(set) var videoResolution: VideoResolution = .p4K
    @Published private(set) var availableVideoResolutions: [VideoResolution] = []
    @Published private(set) var videoCodec: VideoCodec = .hevc
    @Published private(set) var availableVideoCodecs: [VideoCodec] = []
    /// Chooses how every shutter control is presented. The underlying duration
    /// remains the same; only its Speed or Angle representation changes.
    @Published var shutterAngleMode = false
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
    private var audioMeterTimer: DispatchSourceTimer?

    private let queue = DispatchQueue(label: "app.incam.capture", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let selectivePreviewOutput = AVCaptureVideoDataOutput()
    private let selectivePreviewQueue = DispatchQueue(label: "app.incam.selective-color-preview", qos: .utility)
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
        videoResolution = VideoResolution(rawValue: UserDefaults.standard.string(forKey: "incam.capture.resolution") ?? "") ?? .p4K
        let savedFrameRate = UserDefaults.standard.integer(forKey: "incam.capture.frame-rate.v1")
        frameRate = savedFrameRate > 0 ? savedFrameRate : 24
        videoCodec = VideoCodec(rawValue: UserDefaults.standard.string(forKey: "incam.capture.codec.v1") ?? "") ?? .hevc
        videoStabilization = VideoStabilization(rawValue: UserDefaults.standard.string(forKey: "incam.capture.stabilization.v1") ?? "") ?? .auto
        photoSpeedMode = PhotoSpeedMode(rawValue: UserDefaults.standard.string(forKey: "incam.photo.speed.v1") ?? "") ?? .standard
        shutterAngleMode = UserDefaults.standard.bool(forKey: "incam.shutter.angle-mode.v1")
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.health = self.isConfigured ? .ready : .starting
        }
        queue.async { [weak self] in self?.shouldRun = true }
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
    func setLogModeEnabled(_ enabled: Bool) {
        logModeEnabled = enabled
    }

    func stop() {
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

    func toggleMode() {
        guard !isRecording else { return }
        mode = mode == .photo ? .video : .photo
    }

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

    func setCaptureRotation(_ angle: CGFloat) {
        queue.async { [weak self] in
            guard let self else { return }
            self.captureRotation = angle
            // The native preview layer rotates itself, while the Color Mix
            // video-data connection needs the same update explicitly.
            self.rotate(self.selectivePreviewOutput.connection(with: .video), mirrorsFrontPreview: true)
        }
    }

    /// Receives the draft from the color dock. It is read atomically on the
    /// capture queue so moving a color control changes preview frames safely.
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
    func setCameraColorsPreviewEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.setSelectivePreviewEnabled(enabled && self.currentRecipe().hasVisibleAdjustments)
        }
    }

    /// Attaches the direct-texture stream on demand. It is deliberately not a
    /// permanent session output: neutral shooting must not spend battery
    /// converting frames that nobody can see.
    private func setSelectivePreviewEnabled(_ enabled: Bool) {
        guard sessionConfigured else { return }
        guard selectivePreviewEnabled != enabled else { return }
        selectivePreviewEnabled = enabled

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if enabled {
            guard session.canAddOutput(selectivePreviewOutput) else {
                selectivePreviewEnabled = false
                publish(message: "Camera Colors preview is unavailable with this camera format.")
                return
            }
            selectivePreviewOutput.alwaysDiscardsLateVideoFrames = true
            selectivePreviewOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            selectivePreviewOutput.setSampleBufferDelegate(self, queue: selectivePreviewQueue)
            session.addOutput(selectivePreviewOutput)
            rotate(selectivePreviewOutput.connection(with: .video), mirrorsFrontPreview: true)
            setSelectivePreviewPresentation(true)
        } else {
            if session.outputs.contains(selectivePreviewOutput) {
                selectivePreviewOutput.setSampleBufferDelegate(nil, queue: nil)
                session.removeOutput(selectivePreviewOutput)
            }
            setSelectivePreviewPresentation(false)
        }
    }

    /// The presentation sink is a UIKit/Metal view layered directly over the
    /// preview layer. The capture controller owns no UI and retains it weakly.
    func setSelectivePreviewSink(_ sink: SelectiveColorPreviewSink?) {
        selectivePreviewSinkLock.lock()
        selectivePreviewSink = sink
        let active = selectivePreviewEnabled
        let frameRate = pressureThrottledPreview ? 15 : 30
        selectivePreviewSinkLock.unlock()
        sink?.setSelectiveColorPreviewActive(active)
        sink?.setSelectiveColorPreviewFrameRate(frameRate)
    }

    private func setSelectivePreviewPresentation(_ active: Bool) {
        selectivePreviewSinkLock.lock()
        let sink = selectivePreviewSink
        selectivePreviewSinkLock.unlock()
        sink?.setSelectiveColorPreviewActive(active)
        DispatchQueue.main.async { self.selectiveColorPreviewActive = active }
    }

    private func setSelectivePreviewFrameRate(_ framesPerSecond: Int) {
        selectivePreviewSinkLock.lock()
        let sink = selectivePreviewSink
        selectivePreviewSinkLock.unlock()
        sink?.setSelectiveColorPreviewFrameRate(framesPerSecond)
    }

    func setPhotoFormat(_ format: String) {
        guard capabilities.photoFormats.contains(format) else { return }
        photoFormat = format
    }

    /// A user-facing ceiling for both camcorder dragging and +/- buttons.
    /// Hardware limits remain a second, stricter ceiling when necessary.
    func setZoomCap(_ requested: CGFloat) {
        let cap = min(10, max(1, requested))
        zoomCap = cap
        UserDefaults.standard.set(Double(cap), forKey: "incam.zoom.cap.v2")
        if zoom > cap { setZoom(cap) }
    }

    /// A spring-centered rocker: displacement controls velocity, not zoom position.
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
                self.rotate(self.selectivePreviewOutput.connection(with: .video), mirrorsFrontPreview: true)
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
    func setOutputFraming(aspect: CGFloat?) {
        let validAspect = aspect.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        recipeLock.lock()
        outputFramingAspect = validAspect
        recipeLock.unlock()
    }

    /// Swaps between the front wide camera and the current rear camera only
    /// while idle. Each side is a real AVCaptureDevice input—this is never a
    /// mirrored software approximation of the rear feed.
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
                self.rotate(self.selectivePreviewOutput.connection(with: .video), mirrorsFrontPreview: true)
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

    private static func physicalCameras(position: AVCaptureDevice.Position = .back) -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
                                        mediaType: .video, position: position).devices
    }

    private func observeZoom(_ device: AVCaptureDevice) {
        zoomObservation = device.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] device, _ in
            let value = device.videoZoomFactor
            DispatchQueue.main.async { self?.zoom = value }
        }
    }

    /// Mirrors the physical camera's automatic metering in the readouts.
    /// Each observer ignores updates immediately after a manual edit, so the
    /// live Auto values never overwrite an intentional shutter/ISO/WB choice.
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

    func setFrameRate(_ requested: Int) {
        guard !isRecording else { return }
        frameRate = requested
        UserDefaults.standard.set(requested, forKey: "incam.capture.frame-rate.v1")
        // A frame-rate change deliberately establishes its matching 180°-style
        // manual baseline. This keeps the compact readout, its ruler, and the
        // actual device exposure in agreement (for example 24 fps -> 1/50).
        let matchingShutter = CameraExposureDefaults.recommendedShutterSeconds(for: requested)
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
    func toggleShutterAngleMode() {
        shutterAngleMode.toggle()
        UserDefaults.standard.set(shutterAngleMode, forKey: "incam.shutter.angle-mode.v1")
    }

    /// Changes output resolution only while idle. AVFoundation may expose a
    /// different set per device, lens, and active session configuration.
    func setVideoResolution(_ requested: VideoResolution) {
        guard !isRecording, availableVideoResolutions.contains(requested) else { return }
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
    func setPhotoSpeedMode(_ requested: PhotoSpeedMode) {
        guard !isRecording else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.configurePhotoSpeedCapture(requested)
            self.session.commitConfiguration()
        }
    }

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

    func setShutterAuto(_ enabled: Bool) {
        shutterAuto = enabled
        updateExposureAutomation()
    }

    func setISOAuto(_ enabled: Bool) {
        isoAuto = enabled
        updateExposureAutomation()
    }

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
    func toggleExposureLock() {
        if exposureLocked { setExposureAuto(true); return }
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

    func setWhiteBalance(temperature: Float, tint: Float) {
        self.temperature = temperature
        self.tint = tint
        whiteBalanceAuto = false
        tintAuto = false
        applyWhiteBalance()
    }

    func setTemperature(_ temperature: Float) {
        self.temperature = temperature
        whiteBalanceAuto = false
        updateWhiteBalanceAutomation()
    }

    func setTint(_ tint: Float) {
        self.tint = tint
        tintAuto = false
        updateWhiteBalanceAutomation()
    }

    func setWhiteBalanceAuto(_ enabled: Bool) {
        whiteBalanceAuto = enabled
        updateWhiteBalanceAutomation()
    }

    func setTintAuto(_ enabled: Bool) {
        tintAuto = enabled
        updateWhiteBalanceAutomation()
    }

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
        queue.async { [weak self] in
            guard let self, !self.sessionConfigured else {
                guard let self else { return }
                if self.session.isRunning == false { self.session.startRunning() }
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
        let generation = startupGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            self?.queue.async { [weak self] in
                guard let self,
                      self.shouldRun,
                      self.sessionConfigured,
                      !self.deferredSetupCompleted,
                      self.startupGeneration == generation,
                      let device = self.input?.device else { return }

                self.session.beginConfiguration()
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                self.configurePhotoSpeedCapture(self.photoSpeedMode)
                self.configureAudio()
                self.readCapabilities(device)
                self.applyVideoStabilization()
                self.session.commitConfiguration()
                self.deferredSetupCompleted = true

                // Apply the saved 4K/24 (or user-chosen) profile after the
                // primary preview is already usable, not before its first UI
                // frame can accept a tap.
                self.setFrameRate(self.frameRate)
                self.startAudioMetering()
            }
        }
    }

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
    private func installSessionObservers() {
        let center = NotificationCenter.default
        sessionNotificationTokens = [
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

    private func handleSessionInterrupted(_ notification: Notification) {
        let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
        let suffix = reason.map { " (reason \($0.intValue))" } ?? ""
        DispatchQueue.main.async {
            self.health = .recovering("Camera paused by iPhone\(suffix). Waiting to resume.")
        }
        setSelectivePreviewPresentation(false)
    }

    private func handleSessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
        let reset = error?.code == .mediaServicesWereReset
        DispatchQueue.main.async {
            self.health = .recovering(reset ? "Camera service reset. Restoring the session…" : "Camera interrupted. Restoring the session…")
        }
        resumeSessionIfNeeded(reason: reset ? "Camera service restored." : "Camera recovered.")
    }

    private func resumeSessionIfNeeded(reason: String) {
        queue.async { [weak self] in
            guard let self, self.shouldRun, self.sessionConfigured else { return }
            if !self.session.isRunning { self.session.startRunning() }
            self.setSelectivePreviewPresentation(self.selectivePreviewEnabled)
            DispatchQueue.main.async { self.health = .ready }
        }
    }

    private func observeDeviceHealth(_ device: AVCaptureDevice) {
        pressureObservation?.invalidate()
        pressureObservation = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            self?.handleSystemPressure(device.systemPressureState.level)
        }
    }

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
                message = "Camera is warming up."
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
    private func activateAudioSession() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try audio.setActive(true)
        } catch { publish(error) }
    }

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

    func selectAudioInput(_ uid: String) {
        guard !isRecording else { return }
        queue.async { [weak self] in
            let audio = AVAudioSession.sharedInstance()
            guard let input = audio.availableInputs?.first(where: { $0.uid == uid }) else { return }
            do { try audio.setPreferredInput(input) } catch { self?.publish(error) }
        }
    }

    func setAudioGain(_ gain: Float) {
        queue.async { [weak self] in
            let audio = AVAudioSession.sharedInstance()
            guard audio.isInputGainSettable else { return }
            do { try audio.setInputGain(min(1, max(0, gain))) } catch { self?.publish(error) }
        }
    }

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

    func setAudioOutputMode(_ mode: AudioOutputMode) {
        audioOutputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "incam.audio.output-mode.v1")
        queue.async { [weak self] in
            do {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(mode == .speaker ? .speaker : .none)
            } catch { self?.publish(error) }
        }
    }

    func setRecordingFolderName(_ value: String) {
        let cleaned = Self.cleanedFolderName(value)
        recordingFolderName = cleaned
        UserDefaults.standard.set(cleaned, forKey: "incam.media.folder.v1")
    }

    func setRecordingPrefix(_ value: String) {
        let cleaned = Self.cleanedPrefix(value)
        recordingPrefix = cleaned
        UserDefaults.standard.set(cleaned, forKey: "incam.media.prefix.v1")
    }

    func setRecordingNamingMode(_ mode: RecordingNamingMode) {
        recordingNamingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "incam.media.naming.v1")
    }

    private func readCapabilities(_ device: AVCaptureDevice, resolution requestedResolution: VideoResolution? = nil) {
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
        }
        let supportedCodecs = VideoCodec.allCases.filter {
            self.movieOutput.availableVideoCodecTypes.contains(Self.nativeCodec(for: $0))
        }
        let preferredCodec: VideoCodec = supportedCodecs.contains(videoCodec)
            ? videoCodec
            : (supportedCodecs.contains(.hevc) ? .hevc : (supportedCodecs.first ?? .h264))
        // Apply the same capability-checked codec that we publish to the UI;
        // otherwise a fresh session could display HEVC while silently using
        // the output's older default.
        if let connection = movieOutput.connection(with: .video),
           supportedCodecs.contains(preferredCodec),
           movieOutput.supportedOutputSettingsKeys(for: connection).contains(AVVideoCodecKey) {
            movieOutput.setOutputSettings([AVVideoCodecKey: Self.nativeCodec(for: preferredCodec)], for: connection)
        }
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
            if !supportedResolutions.contains(self.videoResolution), let fallback = supportedResolutions.last {
                self.videoResolution = fallback
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

    private func stopRecording() {
        queue.async { [weak self] in self?.movieOutput.stopRecording() }
    }

    /// The main preview and optional Metal Color Mix preview are separate
    /// AVFoundation connections. Mirror the latter at connection level after
    /// its rotation is applied—never with a SwiftUI affine transform—so the
    /// front camera cannot be inverted by a second flip.
    private func rotate(_ connection: AVCaptureConnection?, mirrorsFrontPreview: Bool = false) {
        guard let connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrorsFrontPreview && input?.device.position == .front
        }
        if connection.isVideoRotationAngleSupported(captureRotation) {
            connection.videoRotationAngle = captureRotation
        }
    }

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

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, let recordStartedAt else { return }
            elapsed = Date().timeIntervalSince(recordStartedAt)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        elapsed = 0
        recordStartedAt = nil
    }

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

    func setLevelInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
        guard orientation != .unknown else { return }
        levelInterfaceOrientation = orientation
    }

    /// Motion data is useful only while the visible Level tool is enabled.
    /// Keeping it off otherwise prevents a 20 Hz SwiftUI refresh of the
    /// entire live camera screen and keeps ordinary controls responsive.
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

    private static func sessionPreset(for resolution: VideoResolution) -> AVCaptureSession.Preset {
        switch resolution {
        case .p720: return .hd1280x720
        case .p1080: return .hd1920x1080
        case .p4K: return .hd4K3840x2160
        }
    }

    private static func targetDimensions(for resolution: VideoResolution) -> (width: Int32, height: Int32) {
        switch resolution {
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        case .p4K: return (3840, 2160)
        }
    }

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

    private static func availableFrameRates(for device: AVCaptureDevice,
                                            resolution: VideoResolution) -> [Int] {
        [24, 25, 30, 50, 60, 120].filter { rate in
            device.formats.contains { supports($0, resolution: resolution, frameRate: rate) }
        }
    }

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

    private static func nativeCodec(for codec: VideoCodec) -> AVVideoCodecType {
        switch codec {
        case .h264: return .h264
        case .hevc: return .hevc
        case .proRes422LT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        }
    }

    private static func nativeStabilization(for value: VideoStabilization) -> AVCaptureVideoStabilizationMode {
        switch value {
        case .off: return .off
        case .auto: return .auto
        case .standard: return .standard
        case .cinematic: return .cinematic
        }
    }

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

    private static func todayFolderName() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func cleanedFolderName(_ value: String) -> String {
        let allowed = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return String((allowed.isEmpty ? "ENES" : allowed).prefix(5))
    }

    private static func cleanedPrefix(_ value: String) -> String {
        let allowed = value.uppercased().filter { $0.isLetter || $0.isNumber }
        return String((allowed.isEmpty ? "INCAM" : allowed).prefix(12))
    }

    /// Gallery history names only files produced by this app. It does not hold
    /// Photos identifiers or query the user's existing camera roll.
    private func rememberPrivateMedia(filename: String, kind: InCamSavedMedia.Kind) {
        let defaults = UserDefaults.standard
        var media = (try? JSONDecoder().decode([InCamSavedMedia].self,
                                                from: defaults.data(forKey: Self.savedMediaKey) ?? Data())) ?? []
        let item = InCamSavedMedia(id: UUID(), filename: filename, kind: kind, createdAt: Date())
        media.insert(item, at: 0)
        defaults.set(try? JSONEncoder().encode(Array(media.prefix(500))), forKey: Self.savedMediaKey)
    }

    private func currentRecipe() -> CameraColorRecipe {
        recipeLock.lock()
        defer { recipeLock.unlock() }
        return cameraColorRecipe
    }

    private func currentOutputFramingAspect() -> CGFloat? {
        recipeLock.lock()
        defer { recipeLock.unlock() }
        return outputFramingAspect
    }

    /// Returns a centered crop with the requested width / height. The source
    /// remains otherwise untouched; this is the exact guide ratio chosen by
    /// the person, never an arbitrary screen rectangle.
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

    private func publish(_ error: Error) { publish(message: error.localizedDescription) }
    private func publish(message: String) {
        DispatchQueue.main.async { self.lastError = message }
    }
}

// MARK: - On-demand selective Color Mix preview

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === selectivePreviewOutput else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let recipe = currentRecipe()
        guard recipe.hasVisibleAdjustments else { return }
        // The sink receives the capture texture immediately. It keeps only
        // the newest frame and presents it through an MTKView at display rate,
        // so slow draws are dropped instead of forming a delayed frame queue.
        selectivePreviewSinkLock.lock()
        let sink = selectivePreviewSink
        selectivePreviewSinkLock.unlock()
        sink?.submitSelectiveColorFrame(pixelBuffer, recipe: recipe)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
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
