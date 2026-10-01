import CoreML
import Foundation

/// Phonon-2 (Fermion Research, CC-BY-4.0), a five-value quantized Parakeet TDT 0.6B v3, run
/// in-process through Core ML. `scripts/convert-phonon.sh` builds the models from the
/// published weights, each input size ("bucket") a function of its own:
///   PhononFrontend audio [1, N] at 16 kHz zero-padded, length [1] → features [1, F, 128], frames [1]
///                  (log-mel on the CPU in fp32)
///   PhononEncoder  features, frames → enc [1, T, 640], enc_length [1]  (conformer, Neural Engine)
///   PhononDecoder  token [1, 1], h/c [2, 1, 640] → dec [1, 640], h_out, c_out
///   PhononJoint    enc [1, 640], dec [1, 640] → token [1], duration [1]
/// and TDT greedy decoding runs here.
final class PhononModel: @unchecked Sendable {
    enum ModelError: LocalizedError {
        case missing(URL)
        case badVocab
        case badOutput(String)
        var errorDescription: String? {
            switch self {
            case .missing(let u): "The Phonon-2 model isn't installed (\(u.lastPathComponent) missing)."
            case .badVocab: "The Phonon-2 vocabulary file is unreadable."
            case .badOutput(let s): "Phonon-2 returned no \(s)."
            }
        }
    }

    static let sampleRate = 16_000.0

    /// Where the compiled models live: inside the app when bundled, else Application Support.
    static var directory: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Phonon-2"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("phonon-vocab.json").path) {
            return bundled
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoTty/Models/Phonon-2", isDirectory: true)
    }

    /// Bucket size in samples → that bucket's encoder function.
    private let frontends: [Int: MLModel]
    private let encoders: [Int: MLModel]
    private let decoder: MLModel
    private let joint: MLModel
    private let pieces: [String]
    private let blank: Int32
    private let durations: [Int]
    private let layers: Int
    private let hidden: Int
    /// Padded input lengths in samples; the GPU graph is compiled once per bucket.
    private let buckets: [Int]
    /// Core ML models aren't safe to drive from two threads at once.
    private let lock = NSLock()

    init(directory: URL = PhononModel.directory) throws {
        func load(_ name: String, _ units: MLComputeUnits, function: String? = nil) throws -> MLModel {
            let url = directory.appendingPathComponent("\(name).mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else { throw ModelError.missing(url) }
            let cfg = MLModelConfiguration()
            cfg.computeUnits = units
            cfg.functionName = function
            return try MLModel(contentsOf: url, configuration: cfg)
        }
        decoder = try load("PhononDecoder", .cpuOnly)
        joint = try load("PhononJoint", .cpuOnly)

        let vocabURL = directory.appendingPathComponent("phonon-vocab.json")
        guard let data = try? Data(contentsOf: vocabURL) else { throw ModelError.missing(vocabURL) }
        guard let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pieces = v["pieces"] as? [String], let blank = v["blank"] as? Int,
              let durations = v["durations"] as? [Int], let layers = v["decoder_layers"] as? Int,
              let hidden = v["decoder_hidden"] as? Int,
              let buckets = v["buckets"] as? [Int] else { throw ModelError.badVocab }
        self.pieces = pieces
        self.blank = Int32(blank)
        self.durations = durations
        self.layers = layers
        self.hidden = hidden
        self.buckets = buckets.map { $0 * Int(Self.sampleRate) }
        var frontends: [Int: MLModel] = [:], encoders: [Int: MLModel] = [:]
        for b in buckets {
            let n = b * Int(Self.sampleRate)
            frontends[n] = try load("PhononFrontend", .cpuOnly, function: "s\(b)")
            // The Neural Engine runs the encoder in tens of milliseconds in well under 100 MB; the GPU
            // is faster still but holds ~4 GB of expanded weights. The first load on a Mac compiles
            // each bucket for the Neural Engine (about two minutes each); the system caches that.
            encoders[n] = try load("PhononEncoder", .cpuAndNeuralEngine, function: "s\(b)")
        }
        self.frontends = frontends
        self.encoders = encoders
    }

    /// The longest utterance one call takes; live sessions cut segments before this.
    var maxSamples: Int { buckets.last ?? 0 }

    /// Runs every bucket once so no dictation pays for a graph compile.
    func warmUp() {
        for n in buckets { _ = try? transcribe([Float](repeating: 0, count: n)) }
    }

    /// Transcribes one utterance of 16 kHz mono audio (a quarter second or more).
    func transcribe(_ samples: [Float]) throws -> String {
        guard samples.count >= 4000 else { return "" }
        let samples = samples.count > maxSamples ? Array(samples.suffix(maxSamples)) : samples
        return try lock.withLock { detokenize(try decode(try encode(samples))) }
    }

    // MARK: - Encoder

    /// Returns the encoder frames, [T][hidden] flattened, and T.
    private func encode(_ samples: [Float]) throws -> (frames: MLMultiArray, count: Int) {
        guard let size = buckets.first(where: { $0 >= samples.count }),
              let frontend = frontends[size], let encoder = encoders[size] else {
            throw ModelError.badOutput("encoder for \(samples.count) samples")
        }
        let audio = try MLMultiArray(shape: [1, NSNumber(value: size)], dataType: .float32)
        samples.withUnsafeBufferPointer { src in
            audio.withUnsafeMutableBytes { dst, _ in
                dst.initializeMemory(as: UInt8.self, repeating: 0)
                dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count * 4)
            }
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: samples.count)
        let mel = try frontend.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": audio, "length": length]))
        guard let features = mel.featureValue(for: "features"), let frames = mel.featureValue(for: "frames") else {
            throw ModelError.badOutput("features")
        }
        let out = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": features, "frames": frames]))
        guard let enc = out.featureValue(for: "enc")?.multiArrayValue,
              let n = out.featureValue(for: "enc_length")?.multiArrayValue?[0].intValue else {
            throw ModelError.badOutput("encoder output")
        }
        return (enc, min(n, enc.shape[1].intValue))
    }

    // MARK: - TDT greedy decode

    private func decode(_ enc: (frames: MLMultiArray, count: Int)) throws -> [Int32] {
        let encStep = try MLMultiArray(shape: [1, NSNumber(value: hidden)], dataType: .float32)
        let token = try MLMultiArray(shape: [1, 1], dataType: .int32)
        var h = try MLMultiArray(shape: [NSNumber(value: layers), 1, NSNumber(value: hidden)], dataType: .float32)
        var c = try MLMultiArray(shape: [NSNumber(value: layers), 1, NSNumber(value: hidden)], dataType: .float32)
        for a in [h, c] { a.withUnsafeMutableBytes { p, _ in _ = p.initializeMemory(as: UInt8.self, repeating: 0) } }

        var dec: MLMultiArray!
        func runDecoder(_ t: Int32) throws {
            token[0] = NSNumber(value: t)
            let out = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["token": token, "h": h, "c": c]))
            guard let d = out.featureValue(for: "dec")?.multiArrayValue,
                  let h2 = out.featureValue(for: "h_out")?.multiArrayValue,
                  let c2 = out.featureValue(for: "c_out")?.multiArrayValue else { throw ModelError.badOutput("decoder output") }
            dec = d; h = h2; c = c2
        }
        try runDecoder(blank)

        let stride = enc.frames.strides[1].intValue   // outputs can be padded; step by the real stride
        var ids: [Int32] = []
        var t = 0
        var symbolsHere = 0
        while t < enc.count {
            enc.frames.withUnsafeBytes { src in
                encStep.withUnsafeMutableBytes { dst, _ in
                    copyFrame(src, t * stride, into: dst, count: hidden, type: enc.frames.dataType)
                }
            }
            let out = try joint.prediction(from: MLDictionaryFeatureProvider(dictionary: ["enc": encStep, "dec": dec!]))
            guard let tok = out.featureValue(for: "token")?.multiArrayValue?[0].int32Value,
                  let di = out.featureValue(for: "duration")?.multiArrayValue?[0].intValue else {
                throw ModelError.badOutput("joint output")
            }
            var d = durations[min(max(di, 0), durations.count - 1)]
            if tok == blank {
                d = max(d, 1)
                symbolsHere = 0
            } else {
                ids.append(tok)
                try runDecoder(tok)
                // Guard against a stuck frame, as NeMo's greedy TDT does (max 10 symbols per step).
                symbolsHere = d == 0 ? symbolsHere + 1 : 0
                if symbolsHere >= 10 { d = 1; symbolsHere = 0 }
            }
            t += d
        }
        return ids
    }

    private func copyFrame(_ src: UnsafeRawBufferPointer, _ offset: Int, into dst: UnsafeMutableRawBufferPointer,
                           count: Int, type: MLMultiArrayDataType) {
        let out = dst.bindMemory(to: Float.self)
        if type == .float16 {
            let s = src.bindMemory(to: Float16.self)
            for i in 0..<count { out[i] = Float(s[offset + i]) }
        } else {
            let s = src.bindMemory(to: Float.self)
            for i in 0..<count { out[i] = s[offset + i] }
        }
    }

    // MARK: - Tokens → text

    /// SentencePiece pieces: "▁" starts a word; `<…>` pieces are control tokens.
    private func detokenize(_ ids: [Int32]) -> String {
        var s = ""
        for id in ids where Int(id) < pieces.count {
            let p = pieces[Int(id)]
            if p.hasPrefix("<") && p.hasSuffix(">") { continue }
            s += p
        }
        return s.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
