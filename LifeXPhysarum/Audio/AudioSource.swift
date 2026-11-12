import Foundation
import QuartzCore
import Synchronization

/// Listens to an audio input and, on its own queue, about as often as
/// Physarum steps, turns the newest sound into actors and food with an
/// AudioProcessor, handing the results to the main actor.
nonisolated final class AudioSource: @unchecked Sendable {
    private let capture = AudioCapture()
    private let queue = DispatchQueue(label: "Audio", qos: .userInteractive)
    private let config: Mutex<AudioConfig>
    private let deliver: @MainActor (AudioUpdate) -> Void
    // Confined to `queue`.
    private let processor: AudioProcessor
    private var timer: DispatchSourceTimer?
    private var lastTime: CFTimeInterval?
    private var lastTotal = 0

    init(config: AudioConfig, seed: Int, deliver: @escaping @MainActor (AudioUpdate) -> Void) {
        self.config = Mutex(config)
        self.deliver = deliver
        processor = AudioProcessor(seed: seed)
    }

    /// Starts (or switches to) `input`, or the default input device. Returns the input in use.
    func start(_ input: AudioInput?) async throws -> AudioInput {
        let started = try await capture.start(input)
        queue.async {
            guard self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1 / physarumHz, leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.frame() }
            self.timer = timer
            self.lastTime = nil
            self.lastTotal = 0
            timer.resume()
        }
        return started
    }

    func stop() {
        capture.stop()
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Settings for the frames that follow.
    func setConfig(_ newConfig: AudioConfig) {
        config.withLock { $0 = newConfig }
    }

    // On `queue`.
    private func frame() {
        let now = CACurrentMediaTime()
        let dt = lastTime.map { min(0.25, now - $0) } ?? 1 / physarumHz
        lastTime = now
        let config = config.withLock { $0 }
        let (samples, total) = capture.latest(SpectrumAnalyzer.fftSize)
        // The input restarted (or another took over) if the count went backwards.
        let fresh = total >= lastTotal ? total - lastTotal : total
        lastTotal = total
        let update = processor.process(samples, fresh: min(fresh, samples.count), sampleRate: capture.sampleRate, dt: dt, config)
        let deliver = deliver
        DispatchQueue.main.async { MainActor.assumeIsolated { deliver(update) } }
    }
}
