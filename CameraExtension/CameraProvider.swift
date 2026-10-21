import CoreMediaIO
import CoreText
import Foundation
import IOKit.audio
import os

private let log = Logger(subsystem: VirtualCamera.extensionID, category: "camera")

/// Publishes the one virtual camera device.
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    override init() {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        deviceSource = CameraDeviceSource()
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Couldn't add the camera device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = VirtualCamera.name }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

/// The camera: a source stream that video apps read, and a sink stream the app
/// writes the field into. Frames from the sink are passed straight to the
/// source; while none are arriving (the app isn't running or isn't sending),
/// the source shows a card saying how to start it.
final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var source: CameraStreamSource!
    private var sink: CameraStreamSource!

    // Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "Camera extension", qos: .userInteractive)
    private var sourceRunning = false
    private var sinkClient: CMIOExtensionClient?
    private var sourceTimer: DispatchSourceTimer?
    private var sinkTimer: DispatchSourceTimer?
    private var lastAppFrameTime: UInt64 = 0
    private var placeholder: CVPixelBuffer?
    private let formatDescription: CMFormatDescription

    /// Show the placeholder once the app has been quiet this long.
    private static let appTimeoutNs: UInt64 = 500_000_000

    override init() {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(VirtualCamera.width), height: Int32(VirtualCamera.height),
                                       extensions: nil, formatDescriptionOut: &description)
        formatDescription = description!
        super.init()
        device = CMIOExtensionDevice(localizedName: VirtualCamera.name, deviceID: VirtualCamera.deviceID,
                                     legacyDeviceID: nil, source: self)
        let frameDuration = CMTime(value: 1, timescale: VirtualCamera.framesPerSecond)
        let format = CMIOExtensionStreamFormat(formatDescription: formatDescription, maxFrameDuration: frameDuration,
                                               minFrameDuration: frameDuration, validFrameDurations: nil)
        source = CameraStreamSource(name: "\(VirtualCamera.name) Video", id: VirtualCamera.sourceStreamID,
                                    direction: .source, format: format, owner: self)
        sink = CameraStreamSource(name: "\(VirtualCamera.name) Input", id: VirtualCamera.sinkStreamID,
                                  direction: .sink, format: format, owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Couldn't add the camera streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = VirtualCamera.name }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Streams

    func authorizedToStart(_ direction: CMIOExtensionStream.Direction, for client: CMIOExtensionClient) -> Bool {
        if direction == .sink { queue.sync { sinkClient = client } }
        return true
    }

    func start(_ direction: CMIOExtensionStream.Direction) {
        queue.async {
            switch direction {
            case .source:
                self.sourceRunning = true
                self.sourceTimer = self.timer(hz: Double(VirtualCamera.framesPerSecond)) { $0.sendPlaceholderIfQuiet() }
            case .sink:
                // Polled faster than the frame rate, so a frame waits at most a few ms.
                self.sinkTimer = self.timer(hz: 120) { $0.consumeFromApp() }
            @unknown default:
                break
            }
        }
    }

    func stop(_ direction: CMIOExtensionStream.Direction) {
        queue.async {
            switch direction {
            case .source:
                self.sourceRunning = false
                self.sourceTimer?.cancel()
                self.sourceTimer = nil
            case .sink:
                self.sinkTimer?.cancel()
                self.sinkTimer = nil
                self.sinkClient = nil
            @unknown default:
                break
            }
        }
    }

    // MARK: Frames (on `queue`)

    private func timer(hz: Double, _ fire: @escaping (CameraDeviceSource) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1 / hz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in if let self { fire(self) } }
        t.resume()
        return t
    }

    private func consumeFromApp() {
        guard let client = sinkClient else { return }
        sink.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, _ in
            guard let self, let buffer else { return }
            self.queue.async {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self.lastAppFrameTime = now
                if self.sourceRunning {
                    self.source.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: now)
                }
                self.sink.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
            }
        }
    }

    private func sendPlaceholderIfQuiet() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard now &- lastAppFrameTime > Self.appTimeoutNs else { return }
        if placeholder == nil { placeholder = makePlaceholder() }
        guard let placeholder else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: VirtualCamera.framesPerSecond),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: placeholder,
                                                 formatDescription: formatDescription, sampleTiming: &timing,
                                                 sampleBufferOut: &buffer)
        if let buffer { source.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: now) }
    }

    /// A dark card asking for the app to be opened.
    private func makePlaceholder() -> CVPixelBuffer? {
        let w = VirtualCamera.width, h = VirtualCamera.height
        var pb: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attributes, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func draw(_ text: String, size: CGFloat, alpha: CGFloat, y: CGFloat) {
            let font = CTFontCreateUIFontForLanguage(.system, size, nil)!
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            context.textPosition = CGPoint(x: (CGFloat(w) - width) / 2, y: y)
            CTLineDraw(line, context)
        }
        draw(VirtualCamera.name, size: 56, alpha: 0.9, y: CGFloat(h) / 2 + 10)
        draw("Open the app and turn on Send to Virtual Camera", size: 26, alpha: 0.55, y: CGFloat(h) / 2 - 50)
        log.debug("Made the placeholder frame")
        return pb
    }
}

/// One of the device's streams; its start and stop go to the device.
final class CameraStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let direction: CMIOExtensionStream.Direction
    private unowned let owner: CameraDeviceSource

    init(name: String, id: UUID, direction: CMIOExtensionStream.Direction, format: CMIOExtensionStreamFormat,
         owner: CameraDeviceSource) {
        self.format = format
        self.direction = direction
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            properties.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                                  .streamSinkBufferUnderrunCount, .streamSinkEndOfData])
        }
        return properties
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: VirtualCamera.framesPerSecond) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 4 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        if properties.contains(.streamSinkBufferUnderrunCount) { p.sinkBufferUnderrunCount = 0 }
        if properties.contains(.streamSinkEndOfData) { p.sinkEndOfData = 0 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        owner.authorizedToStart(direction, for: client)
    }

    func startStream() throws { owner.start(direction) }
    func stopStream() throws { owner.stop(direction) }
}
