import AudioToolbox
import AVFoundation
import CoreAudio
import Speech

/// One hold = one session: microphone → format conversion → SpeechAnalyzer.
/// The analyzer is single-use (it finishes when input ends), so each session builds a
/// new one; `.processLifetime` model retention keeps the model warm between sessions.
@MainActor
final class DictationEngine {
    struct Callbacks {
        var volatile: (String) -> Void
        var final: (String) -> Void
        var level: (Float) -> Void
        /// The audio device changed mid-session (e.g. AirPods connected); the mic has stopped.
        var interrupted: () -> Void
    }

    enum EngineError: LocalizedError {
        case unsupportedLocale(Locale)
        case noAudioFormat
        case noMicrophone
        var errorDescription: String? {
            switch self {
            case .noMicrophone: "No microphone input is available right now."
            case .unsupportedLocale(let l): "Speech recognition doesn't support \(l.identifier)."
            case .noAudioFormat: "No compatible audio format for the speech model."
            }
        }
    }

    /// A fresh engine per session: an AVAudioEngine keeps the input format it saw first,
    /// and after the input device changes (AirPods connecting, say) installing a tap with
    /// that stale format raises an Objective-C exception that Swift can't catch.
    private var audio: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var finishSignal: AsyncStream<Void>.Continuation?
    private var sessionTask: Task<Void, Never>?

    /// Asset status for the current locale, for the settings window.
    private(set) var modelStatus = "Checking…"
    private(set) var model = ModelState.checking
    var onStatusChange: (() -> Void)?

    enum ModelState: Equatable {
        case checking
        case downloading(Double)   // 0…1
        case ready
        case failed(String)
    }

    /// Custom words, sent to the model as context so it favours these spellings.
    var contextualWords: () -> [String] = { [] }

    // MARK: - Modules

    private static let analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    /// SpeechTranscriber is the newer model; DictationTranscriber covers devices or
    /// locales it doesn't support.
    private func makeModule(for locale: Locale) async throws -> any SpeechModule {
        if SpeechTranscriber.isAvailable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return SpeechTranscriber(locale: l, transcriptionOptions: [],
                                     reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        }
        if let l = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return DictationTranscriber(locale: l, contentHints: [], transcriptionOptions: [.punctuation],
                                        reportingOptions: [.volatileResults, .frequentFinalization], attributeOptions: [])
        }
        throw EngineError.unsupportedLocale(locale)
    }

    /// Downloads the on-device model for the chosen locale if needed.
    func ensureModel() async {
        ensureGeneration += 1
        let gen = ensureGeneration
        setStatus("Checking…", .checking)
        do {
            let module = try await makeModule(for: Pref.locale)
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                setStatus("Downloading speech model…", .downloading(0))
                let progress = req.progress
                let poll = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self, gen == self.ensureGeneration else { return }
                        let f = min(max(progress.fractionCompleted, 0), 1)
                        self.setStatus("Downloading speech model · \(Int(f * 100))%", .downloading(f))
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }
                defer { poll.cancel() }
                try await req.downloadAndInstall()
            }
            guard gen == ensureGeneration else { return }
            setStatus("Ready (\(Pref.locale.identifier))", .ready)
        } catch {
            guard gen == ensureGeneration else { return }
            setStatus("Error: \(error.localizedDescription)", .failed(error.localizedDescription))
        }
    }

    private var ensureGeneration = 0

    private func setStatus(_ s: String, _ m: ModelState) {
        modelStatus = s
        model = m
        onStatusChange?()
    }

    static func supportedLocales() async -> [Locale] {
        let a = await SpeechTranscriber.supportedLocales
        return a.isEmpty ? await DictationTranscriber.supportedLocales : a
    }

    // MARK: - Session

    /// Starts listening. Audio is captured immediately and buffered while the
    /// analyzer spins up, so the first word isn't lost.
    func start(_ cb: Callbacks) throws {
        cancel()

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let (finishStream, finishCont) = AsyncStream<Void>.makeStream()
        input = cont
        finishSignal = finishCont

        let converter = FormatConverter()
        let tap: AVAudioNodeTapBlock = { buf, _ in
            cb.levelSink(buf)
            if let out = converter.convert(buf) { cont.yield(AnalyzerInput(buffer: out)) }
        }
        let micFormat = try startCapture(tap: tap, onLost: cb.interrupted)

        let locale = Pref.locale
        let words = contextualWords()
        sessionTask = Task { [weak self] in
            do {
                guard let module = try await self?.makeModule(for: locale) else { return }
                guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: micFormat)
                else { throw EngineError.noAudioFormat }
                converter.target = fmt

                let analyzer = SpeechAnalyzer(modules: [module], options: Self.analyzerOptions)
                if !words.isEmpty {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = words
                    try? await analyzer.setContext(context)
                }
                try await analyzer.prepareToAnalyze(in: fmt)
                try await analyzer.start(inputSequence: stream)
                async let consumed: Void = Self.consume(module, cb)

                for await _ in finishStream {}   // until finish() or cancel()
                if Task.isCancelled {
                    await analyzer.cancelAndFinishNow()
                } else {
                    try await analyzer.finalizeAndFinishThroughEndOfInput()
                }
                try await consumed
            } catch is CancellationError {
            } catch {
                NSLog("HoTty dictation error: \(error)")
            }
        }
    }

    private static func consume(_ module: any SpeechModule, _ cb: Callbacks) async throws {
        func handle(text: AttributedString, isFinal: Bool) async {
            guard !Task.isCancelled else { return }
            let s = String(text.characters)
            await MainActor.run { isFinal ? cb.final(s) : cb.volatile(s) }
        }
        if let t = module as? SpeechTranscriber {
            for try await r in t.results { await handle(text: r.text, isFinal: r.isFinal) }
        } else if let t = module as? DictationTranscriber {
            for try await r in t.results { await handle(text: r.text, isFinal: r.isFinal) }
        }
    }

    /// Stops the mic and waits until every pending word has been finalized and delivered.
    func finish() async {
        stopAudio()
        input?.finish()
        finishSignal?.finish()
        input = nil
        finishSignal = nil
        let task = sessionTask
        sessionTask = nil
        _ = await task?.value
    }

    /// Stops immediately and drops anything not yet delivered.
    func cancel() {
        stopAudio()
        sessionTask?.cancel()
        input?.finish()
        finishSignal?.finish()
        input = nil
        finishSignal = nil
        sessionTask = nil
    }

    /// Starts a fresh engine feeding `tap`. When the input device changes mid-session
    /// (AirPods switching into their microphone mode fires this right after start),
    /// capture restarts on the new device and keeps feeding the same analyzer input;
    /// `onLost` runs only if no microphone is available any more.
    @discardableResult
    private func startCapture(tap: @escaping AVAudioNodeTapBlock, onLost: @escaping () -> Void) throws -> AVAudioFormat {
        stopAudio()
        let audio = AVAudioEngine()
        let node = audio.inputNode
        Microphones.select(Pref.micUID, on: node)
        let micFormat = node.outputFormat(forBus: 0)
        // Mid-switch devices report an empty format; installing a tap on it would abort.
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw EngineError.noMicrophone }
        // format: nil taps in the node's current format, so it can never mismatch.
        node.installTap(onBus: 0, bufferSize: 1024, format: nil, block: tap)
        audio.prepare()
        try audio.start()
        self.audio = audio
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.input != nil else { return }   // session already over
                do {
                    try self.startCapture(tap: tap, onLost: onLost)
                } catch {
                    NSLog("HoTty: microphone lost after device change: \(error)")
                    onLost()
                }
            }
        }
        return micFormat
    }

    private func stopAudio() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let audio else { return }
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        self.audio = nil
    }
}

private extension DictationEngine.Callbacks {
    /// RMS of the first channel, mapped to 0…1 for the overlay's level meter.
    func levelSink(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0], buf.frameLength > 0 else { return }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-6))
        let norm = max(0, min(1, (db + 50) / 40))
        let level = self.level
        DispatchQueue.main.async { level(norm) }
    }
}

/// Converts mic buffers to the analyzer's format. Buffers that arrive before the
/// target format is known are held and converted once it is set.
private final class FormatConverter: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var pending: [AVAudioPCMBuffer] = []
    private var _target: AVAudioFormat?

    var target: AVAudioFormat? {
        get { lock.withLock { _target } }
        set { lock.withLock { _target = newValue } }
    }

    /// Returns converted audio, or nil while still waiting for the target format.
    /// Once the target is known, the backlog is prepended to the next buffer.
    func convert(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        guard let target = _target else {
            if let copy = buf.copy() as? AVAudioPCMBuffer { pending.append(copy) }
            return nil
        }
        let backlog = pending
        pending.removeAll()
        let all = backlog + [buf]
        let merged = all.count == 1 ? buf : Self.concat(all) ?? buf
        if merged.format == target { return merged }
        if converter == nil || converter?.inputFormat != merged.format || converter?.outputFormat != target {
            converter = AVAudioConverter(from: merged.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / merged.format.sampleRate
        let cap = AVAudioFrameCount(Double(merged.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return merged
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }

    private static func concat(_ bufs: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let fmt = bufs.first?.format else { return nil }
        let total = bufs.reduce(0) { $0 + $1.frameLength }
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total),
              let dst = out.floatChannelData else { return nil }
        var offset = 0
        for b in bufs {
            guard let src = b.floatChannelData else { return nil }
            for c in 0..<Int(fmt.channelCount) {
                (dst[c] + offset).update(from: src[c], count: Int(b.frameLength))
            }
            offset += Int(b.frameLength)
        }
        out.frameLength = total
        return out
    }
}

/// Audio input devices, and picking one for a session.
enum Microphones {
    struct Device: Identifiable, Hashable {
        let id: String      // Core Audio UID
        let name: String
    }

    static func all() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The device a session would use right now.
    static func currentName() -> String {
        let uid = Pref.micUID
        if !uid.isEmpty, let d = all().first(where: { $0.id == uid }) { return d.name }
        return AVCaptureDevice.default(for: .audio)?.localizedName ?? "No microphone"
    }

    /// Points the engine's input at the chosen device. An unplugged or unknown device
    /// leaves the system default in place.
    static func select(_ uid: String, on node: AVAudioInputNode) {
        guard !uid.isEmpty, let id = deviceID(forUID: uid), let unit = node.audioUnit else { return }
        var dev = id
        let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if err != noErr { NSLog("HoTty: couldn't select microphone %@: %d", uid, err) }
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), p, &size, &id)
        }
        return err == noErr && id != 0 ? id : nil
    }
}
