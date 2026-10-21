import AVFoundation
import Synchronization

/// A camera the user can pick.
nonisolated struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
}

/// Captures the camera on its own queue, turns each frame into actors and food
/// with a CameraProcessor, and hands the results to the main actor.
nonisolated final class CameraSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case denied, noCamera, cantUse(String)

        var errorDescription: String? {
            switch self {
            case .denied: "Life × Physarum isn’t allowed to use the camera. You can allow it in System Settings → Privacy & Security → Camera."
            case .noCamera: "No camera is connected."
            case .cantUse(let name): "“\(name)” couldn’t be started. It may be in use by another app."
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "Camera", qos: .userInteractive)
    private let config: Mutex<CameraConfig>
    private let deliver: @MainActor (CameraUpdate) -> Void
    // Confined to `queue`.
    private let processor: CameraProcessor
    private var input: AVCaptureDeviceInput?

    init(config: CameraConfig, seed: Int, deliver: @escaping @MainActor (CameraUpdate) -> Void) {
        self.config = Mutex(config)
        self.deliver = deliver
        processor = CameraProcessor(seed: seed)
        super.init()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.sessionPreset = .high
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    /// Video cameras: built in, external (USB), and Continuity Camera iPhones.
    static func devices() -> [CameraDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified)
            .devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The camera macOS prefers (as in FaceTime), else the default, else any.
    private static func defaultDevice() -> AVCaptureDevice? {
        AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
            ?? AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                mediaType: .video, position: .unspecified).devices.first
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Starts (or switches to) a camera: the one with `deviceID`, or the system's default.
    /// Returns the camera in use.
    func start(deviceID: String?) async throws -> CameraDevice {
        guard await Self.requestAccess() else { throw Failure.denied }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? Self.defaultDevice() else {
                        throw Failure.noCamera
                    }
                    try self.use(device)
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume(returning: CameraDevice(id: device.uniqueID, name: device.localizedName))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Settings for the frames that follow.
    func setConfig(_ newConfig: CameraConfig) {
        config.withLock { $0 = newConfig }
    }

    // On `queue`.
    private func use(_ device: AVCaptureDevice) throws {
        guard input?.device != device else { return }
        let newInput: AVCaptureDeviceInput
        do { newInput = try AVCaptureDeviceInput(device: device) } catch { throw Failure.cantUse(device.localizedName) }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            if let input { session.addInput(input) }
            throw Failure.cantUse(device.localizedName)
        }
        session.addInput(newInput)
        input = newInput
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let config = config.withLock { $0 }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = cameraFrame(from: pixels, gridSize: config.gridSize, mirrored: config.mirrored)
        else { return }
        let update = processor.process(frame, config)
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(update) } }
    }
}
