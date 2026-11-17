import AppKit
import AVFoundation
import CoreAudio
import Synchronization

/// Something the app can listen to: an input device (a microphone, an audio
/// interface, or a virtual device such as BlackHole or Loopback), everything
/// the Mac is playing, or one app's sound.
nonisolated struct AudioInput: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case device, system, app
        #if DEBUG
        /// A generated tune, for trying styles without permissions.
        case test
        #endif
    }

    /// A device's UID, `systemID`, or "app:" and a bundle ID.
    let id: String
    let name: String
    let kind: Kind

    static let systemID = "system"
    static let system = AudioInput(id: systemID, name: "System Audio", kind: .system)
    #if DEBUG
    static let test = AudioInput(id: "test", name: "Test Tune", kind: .test)
    #endif

    static func app(bundleID: String, name: String) -> AudioInput {
        AudioInput(id: "app:" + bundleID, name: name, kind: .app)
    }

    var bundleID: String? { kind == .app ? String(id.dropFirst(4)) : nil }

    /// Which kind an ID names, for settings saved with one.
    static func kind(of id: String) -> Kind {
        id == systemID ? .system : id.hasPrefix("app:") ? .app : .device
    }
}

/// Listens to an AudioInput through Core Audio and keeps its newest samples,
/// left and right. Taps (system and app sound) are private to this app and
/// leave the sound playing as usual.
nonisolated final class AudioCapture: @unchecked Sendable {
    enum Failure: LocalizedError {
        case denied, noInput, gone(String), cantUse(String, OSStatus), unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .denied: "Life × Physarum isn’t allowed to use the microphone. You can allow it in System Settings → Privacy & Security → Microphone."
            case .noInput: "No audio input is connected."
            case .gone(let name): "“\(name)” isn’t available. If it’s an app, play something in it first."
            case .cantUse(let name, let status): "“\(name)” couldn’t be started (error \(status))."
            case .unsupportedFormat(let name): "“\(name)” sends audio in a format Life × Physarum can’t read."
            }
        }
    }

    /// Samples kept: enough for one spectrum, at any common sample rate.
    static let capacity = 16_384

    private let queue = DispatchQueue(label: "Audio capture", qos: .userInteractive)
    /// Starts and stops run here, in order and off the main thread: Core Audio
    /// can block them for as long as a permission prompt waits for an answer.
    private let control = DispatchQueue(label: "Audio capture control", qos: .userInitiated)
    private let ring = Mutex(SampleRing(capacity: capacity))
    private let rate = Mutex(48_000.0)
    // Touched only on `control`.
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    #if DEBUG
    private var testTimer: DispatchSourceTimer?
    #endif

    deinit { stopNow() }

    var sampleRate: Double { rate.withLock { $0 } }

    /// The newest `count` samples of each channel, oldest first, and how many have arrived since the input started.
    func latest(_ count: Int) -> (samples: StereoSamples, total: Int) {
        ring.withLock { ($0.latest(count), $0.total) }
    }

    /// Input devices with at least one input channel, the system's sound, and
    /// apps that have played sound. Apps are listed by name, once each.
    static func inputs() -> [AudioInput] {
        let devices = deviceIDs().filter { inputChannels($0) > 0 && !(readUInt32($0, kAudioDevicePropertyIsHidden) == 1) }
            .compactMap { id -> AudioInput? in
                guard let uid = readString(id, kAudioDevicePropertyDeviceUID), let name = readString(id, kAudioObjectPropertyName) else { return nil }
                return AudioInput(id: uid, name: name, kind: .device)
            }
        var seen: Set<String> = [], apps: [AudioInput] = []
        for process in processIDs() {
            guard let bundleID = readString(process, kAudioProcessPropertyBundleID), bundleID != Bundle.main.bundleIdentifier,
                  let pid = readValue(process, kAudioProcessPropertyPID, as: pid_t.self),
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  app.bundleIdentifier == bundleID, let name = app.localizedName, seen.insert(bundleID).inserted
            else { continue }
            apps.append(.app(bundleID: bundleID, name: name))
        }
        return devices + [.system] + apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    /// Calls `changed` on the main queue when devices come or go, or an app starts using sound.
    static func observeChanges(_ changed: @escaping @MainActor () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList] {
            var address = propertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { changed() }
            }
        }
    }

    /// Starts listening to `input` (the default input device if nil), stopping
    /// whatever was playing before. Returns the input in use.
    func start(_ input: AudioInput?) async throws -> AudioInput {
        if (input?.kind ?? .device) == .device, !(await Self.requestMicrophoneAccess()) { throw Failure.denied }
        return try await withCheckedThrowingContinuation { continuation in
            control.async { continuation.resume(with: Result { try self.startNow(input) }) }
        }
    }

    /// Stops listening, once any start before it has finished.
    func stop() {
        control.async { self.stopNow() }
    }

    // On `control`.
    private func startNow(_ input: AudioInput?) throws -> AudioInput {
        stopNow()
        let kind = input?.kind ?? .device
        #if DEBUG
        if kind == .test { return startTestTune() }
        #endif
        let resolved: AudioInput
        let format: AudioStreamBasicDescription
        switch kind {
        case .device:
            let id = input.flatMap { Self.deviceID(uid: $0.id) } ?? Self.defaultInputID()
            guard let id else { throw input.map { Failure.gone($0.name) } ?? Failure.noInput }
            resolved = AudioInput(id: Self.readString(id, kAudioDevicePropertyDeviceUID) ?? input?.id ?? "",
                                  name: Self.readString(id, kAudioObjectPropertyName) ?? input?.name ?? "Input", kind: .device)
            guard let f = Self.inputFormat(id) else { throw Failure.unsupportedFormat(resolved.name) }
            deviceID = id
            format = f
        default:
            resolved = input!
            format = try makeTap(resolved)
            deviceID = aggregateID
        }
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            stopNow()
            throw Failure.unsupportedFormat(resolved.name)
        }
        rate.withLock { $0 = format.mSampleRate > 0 ? format.mSampleRate : 48_000 }
        ring.withLock { $0.clear() }

        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            self?.ring.withLock { $0.appendChannels(buffers) }
        }
        if status == noErr { status = AudioDeviceStart(deviceID, procID) }
        guard status == noErr else {
            stopNow()
            throw Failure.cantUse(resolved.name, status)
        }
        return resolved
    }

    // On `control`, or in deinit.
    private func stopNow() {
        #if DEBUG
        testTimer?.cancel()
        testTimer = nil
        #endif
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    #if DEBUG
    /// Plays a looping tune into the ring: a bass line under arpeggiated chords, with plucked
    /// envelopes, the bass panned left and the chords right.
    private func startTestTune() -> AudioInput {
        let sampleRate = 48_000.0, chunk = 480
        rate.withLock { $0 = sampleRate }
        ring.withLock { $0.clear() }
        let roots = [45.0, 41, 48, 43] // A, F, C, G (MIDI)
        var n = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Double(chunk) / sampleRate)
        timer.setEventHandler { [weak self] in
            let parts = (0..<chunk).map { i -> (bass: Double, lead: Double) in
                let t = Double(n + i) / sampleRate
                let bar = Int(t / 2) % roots.count, beat = t.truncatingRemainder(dividingBy: 0.25)
                func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }
                let bass = sin(2 * .pi * hz(roots[bar]) * t) * exp(-t.truncatingRemainder(dividingBy: 0.5) * 3)
                let note = roots[bar] + 24 + [0, 4, 7, 12][Int(t / 0.25) % 4]
                let lead = (sin(2 * .pi * hz(note) * t) + 0.3 * sin(4 * .pi * hz(note) * t)) * exp(-beat * 12)
                return (bass, lead)
            }
            n += chunk
            let left = parts.map { Float(0.5 * $0.bass + 0.1 * $0.lead) }
            let right = parts.map { Float(0.15 * $0.bass + 0.35 * $0.lead) }
            self?.ring.withLock { $0.append(left: left, right: right) }
        }
        testTimer = timer
        timer.resume()
        return .test
    }
    #endif

    /// Taps the system's or an app's output into a private aggregate device,
    /// as Apple's "Capturing system audio with Core Audio taps" describes. Returns the tap's format.
    private func makeTap(_ input: AudioInput) throws -> AudioStreamBasicDescription {
        let description: CATapDescription
        if let bundleID = input.bundleID {
            // An app's helper processes (com.example.App.helper) play its sound too.
            let processes = Self.processIDs().filter { p in
                Self.readString(p, kAudioProcessPropertyBundleID).map { $0 == bundleID || $0.hasPrefix(bundleID + ".") } ?? false
            }
            guard !processes.isEmpty else { throw Failure.gone(input.name) }
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        } else {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        description.name = "Life × Physarum"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw Failure.cantUse(input.name, status) }

        let outputUID = Self.readID(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice)
            .flatMap { Self.readString($0, kAudioDevicePropertyDeviceUID) }
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Life × Physarum Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        if let outputUID {
            // The output device clocks the aggregate.
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stopNow()
            throw Failure.cantUse(input.name, status)
        }
        guard let format = Self.readValue(tapID, kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self) else {
            stopNow()
            throw Failure.unsupportedFormat(input.name)
        }
        return format
    }

    // MARK: Core Audio properties

    private static func propertyAddress(_ selector: AudioObjectPropertySelector,
                                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func readValue<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, as: T.Type) -> T? {
        var address = propertyAddress(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    private static func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        readValue(object, selector, as: UInt32.self)
    }

    private static func readID(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        readValue(object, selector, as: AudioObjectID.self).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func readIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = propertyAddress(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func deviceIDs() -> [AudioObjectID] {
        readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
    }

    private static func processIDs() -> [AudioObjectID] {
        readIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    }

    private static func defaultInputID() -> AudioObjectID? {
        readID(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func deviceID(uid: String) -> AudioObjectID? {
        deviceIDs().first { readString($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func inputChannels(_ device: AudioObjectID) -> Int {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The format the device's first input stream hands IOProcs.
    private static func inputFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
        guard let stream = readIDs(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).first else { return nil }
        return readValue(stream, kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
    }
}

/// The newest samples of each channel, in a circular buffer.
nonisolated struct SampleRing {
    private var left: [Float]
    private var right: [Float]
    private var next = 0
    private var scratch = StereoSamples(mono: [])
    /// Samples appended since the ring was made or cleared.
    private(set) var total = 0

    init(capacity: Int) {
        left = [Float](repeating: 0, count: capacity)
        right = left
    }

    mutating func clear() {
        left = [Float](repeating: 0, count: left.count)
        right = left
        next = 0
        total = 0
    }

    /// Appends mono samples to both channels.
    mutating func append(_ samples: some Collection<Float>) {
        append(left: samples, right: samples)
    }

    mutating func append(left l: some Collection<Float>, right r: some Collection<Float>) {
        for (a, b) in zip(l, r) {
            left[next] = a
            right[next] = b
            next = (next + 1) % left.count
        }
        total += min(l.count, r.count)
    }

    /// Appends 32-bit float audio from every channel of every buffer (interleaved
    /// or not), numbered in order across the buffers: the even channels averaged
    /// into the left, the odd into the right, so a stereo pair lands as itself.
    /// A single channel goes to both.
    mutating func appendChannels(_ buffers: UnsafeMutableAudioBufferListPointer) {
        let channels = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return }
        let frames = buffers.map { Int($0.mDataByteSize) / (4 * max(1, Int($0.mNumberChannels))) }.min() ?? 0
        scratch.left.removeAll(keepingCapacity: true)
        scratch.left.append(contentsOf: repeatElement(0, count: frames))
        scratch.right.removeAll(keepingCapacity: true)
        scratch.right.append(contentsOf: repeatElement(0, count: frames))
        var channel = 0
        for buffer in buffers {
            let stride = Int(buffer.mNumberChannels)
            defer { channel += stride }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for c in 0..<stride {
                if (channel + c) % 2 == 0 || channels == 1 {
                    for f in 0..<frames { scratch.left[f] += data[f * stride + c] }
                }
                if (channel + c) % 2 == 1 || channels == 1 {
                    for f in 0..<frames { scratch.right[f] += data[f * stride + c] }
                }
            }
        }
        let leftScale = 1 / Float((channels + 1) / 2), rightScale = 1 / Float(max(1, channels / 2))
        append(left: scratch.left.lazy.map { $0 * leftScale }, right: scratch.right.lazy.map { $0 * rightScale })
    }

    /// The newest `count` samples of each channel (at most the capacity), oldest first.
    func latest(_ count: Int) -> StereoSamples {
        let count = min(count, left.count)
        let start = (next - count + left.count) % left.count
        func slice(_ buffer: [Float]) -> [Float] {
            if start + count <= buffer.count { return Array(buffer[start..<start + count]) }
            return Array(buffer[start...] + buffer[..<(start + count - buffer.count)])
        }
        return StereoSamples(left: slice(left), right: slice(right))
    }
}

