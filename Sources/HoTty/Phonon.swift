import AVFoundation
import Foundation

/// Keeps the one Phonon-2 model for the process: loads it when the engine is chosen, warms
/// every input size up front, and drops it when switching back to Apple's recognizer.
@MainActor
final class PhononEngine {
    static let shared = PhononEngine()

    private(set) var model: PhononModel?
    private var loading: Task<PhononModel, Error>?

    var isReady: Bool { model != nil }

    func ensureLoaded(status: @escaping (String) -> Void) async throws {
        if model != nil { return }
        let task = loading ?? Task.detached(priority: .userInitiated) {
            let m = try PhononModel()
            await MainActor.run { status("Warming up Phonon-2…") }
            m.warmUp()
            return m
        }
        loading = task
        status("Loading Phonon-2… (the first time on a Mac takes about 5 minutes)")
        do {
            model = try await task.value
        } catch {
            loading = nil
            throw error
        }
    }

    func unload() {
        loading = nil
        model = nil
    }
}

/// One hold's live transcription, the way Fermion's `phonon listen` does it: the in-flight
/// phrase is re-decoded every half second of new audio (`partial`, replacing the last one),
/// and a phrase is finalized after 0.7 s of silence or at the model's length cap (`final`).
final class PhononLive: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PhononModel.sampleRate,
                                      channels: 1, interleaved: false)!

    private static let frame = 320                   // 20 ms energy frames
    private static let firstPartial = 5_600          // 0.35 s
    private static let partialEvery = 8_000          // 0.5 s
    private static let silenceToFinal = 11_200       // 0.7 s
    private static let preroll = 4_800               // audio kept from before speech starts
    private static let floorRMS: Float = 0.006       // room tone
    private static let peakFraction: Float = 0.08    // of the phrase's loudest frame

    private let model: PhononModel
    private let onPartial: (String) -> Void
    private let onFinal: (String) -> Void
    private let queue = DispatchQueue(label: "llc.fungee.hotty.phonon", qos: .userInitiated)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var segment: [Float] = []
    private var pendingFrame: [Float] = []
    private var speech = false
    private var peak: Float = 0
    private var silentRun = 0
    private var lastPartialAt = 0
    private var partialQueued = false
    private var segmentID = 0
    private var cancelled = false

    init(model: PhononModel, partial: @escaping (String) -> Void, final: @escaping (String) -> Void) {
        self.model = model
        onPartial = partial
        onFinal = final
    }

    /// Takes 16 kHz mono float audio; called on the audio thread.
    func append(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))
        let job = lock.withLock { () -> (() -> Void)? in
            guard !cancelled else { return nil }
            segment.append(contentsOf: samples)
            pendingFrame.append(contentsOf: samples)
            var used = 0
            while pendingFrame.count - used >= Self.frame {
                var sum: Float = 0
                for i in used..<(used + Self.frame) { sum += pendingFrame[i] * pendingFrame[i] }
                used += Self.frame
                let rms = sqrt(sum / Float(Self.frame))
                peak = max(peak, rms)
                if rms > max(Self.floorRMS, peak * Self.peakFraction) {
                    speech = true
                    silentRun = 0
                } else {
                    silentRun += Self.frame
                }
            }
            pendingFrame.removeFirst(used)

            guard speech else {
                // Nothing said yet: keep only a short lead-in.
                if segment.count > Self.preroll * 2 { segment.removeFirst(segment.count - Self.preroll) }
                peak = 0
                return nil
            }
            if silentRun >= Self.silenceToFinal || segment.count >= model.maxSamples - Self.partialEvery {
                return finalJob()
            }
            guard !partialQueued,
                  segment.count - lastPartialAt >= (lastPartialAt == 0 ? Self.firstPartial : Self.partialEvery)
            else { return nil }
            partialQueued = true
            lastPartialAt = segment.count
            let snapshot = segment, id = segmentID
            return { [weak self] in self?.runPartial(snapshot, id) }
        }
        if let job { queue.async(execute: job) }
    }

    /// Finalizes whatever is buffered and returns once its text has been delivered.
    func finish() async {
        let job = lock.withLock { () -> (() -> Void)? in speech && !cancelled ? finalJob() : nil }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                job?()
                c.resume()
            }
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    /// Call with `lock` held: hands the current phrase to a final decode and starts a new one.
    private func finalJob() -> () -> Void {
        let snapshot = segment
        segment = []
        speech = false
        peak = 0
        silentRun = 0
        lastPartialAt = 0
        segmentID += 1
        return { [weak self] in
            guard let self else { return }
            let text = (try? self.model.transcribe(snapshot)) ?? ""
            guard !text.isEmpty, !self.lock.withLock({ self.cancelled }) else { return }
            self.onFinal(text)
        }
    }

    private func runPartial(_ audio: [Float], _ id: Int) {
        let text = (try? model.transcribe(audio)) ?? ""
        let current = lock.withLock {
            partialQueued = false
            return id == segmentID && !cancelled
        }
        if current, !text.isEmpty { onPartial(text) }
    }
}
