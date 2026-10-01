import Foundation

/// How a dictation hold is detected.
enum TriggerMode: String, CaseIterable, Identifiable {
    /// Press the trackpad down and keep it pressed without moving.
    case clickHold
    /// Rest one finger on the trackpad without clicking or moving (private MultitouchSupport).
    case touchHold

    var id: String { rawValue }
    var title: String {
        switch self {
        case .clickHold: "Press & hold (click)"
        case .touchHold: "Rest finger (no click)"
        }
    }
}

/// How in-progress (volatile) speech is shown while talking.
enum LiveMode: String, CaseIterable, Identifiable {
    /// Volatile words float in an overlay; only finalized phrases are typed.
    case overlay
    /// Volatile words are typed into the field and corrected with backspaces.
    case inline

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overlay: "Preview overlay"
        case .inline: "Type live into the field"
        }
    }
}

/// Where dictated text goes when a hold starts on a spot with no selection under it.
enum CaretPlacement: String, CaseIterable, Identifiable {
    /// Click at the pointer first, so text lands where you held.
    case atPointer
    /// Leave the caret alone and type at its current position.
    case existing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .atPointer: "Move caret to where I hold"
        case .existing: "Keep the current caret"
        }
    }
}

/// Which speech recognizer turns audio into text.
enum SpeechEngine: String, CaseIterable, Identifiable {
    /// Apple's on-device SpeechAnalyzer, in any language it supports.
    case apple
    /// Fermion Research's Phonon-2, run in-process through Core ML. English only.
    case phonon

    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple (built-in)"
        case .phonon: "Phonon-2 (English)"
        }
    }
}

/// UserDefaults keys. Views bind with @AppStorage; engines read UserDefaults directly,
/// which is thread-safe and lets the event-tap thread read without hopping to main.
enum Pref {
    static let triggerMode = "triggerMode"
    static let liveMode = "liveMode"
    static let caretPlacement = "caretPlacement"
    static let holdDuration = "holdDuration"
    static let localeID = "localeID"
    static let speechEngine = "speechEngine"
    static let playSounds = "playSounds"
    static let ignoreThumbZone = "ignoreThumbZone"
    static let micUIDKey = "microphoneUID"
    static let onboarded = "onboardingDone"

    static let holdDurationRange: ClosedRange<Double> = 0.15...1.5

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            triggerMode: TriggerMode.clickHold.rawValue,
            liveMode: LiveMode.overlay.rawValue,
            caretPlacement: CaretPlacement.atPointer.rawValue,
            holdDuration: 0.4,
            localeID: "",
            speechEngine: SpeechEngine.apple.rawValue,
            playSounds: true,
            ignoreThumbZone: true,
            micUIDKey: "",
            onboarded: false,
        ])
    }

    static var d: UserDefaults { .standard }

    static var trigger: TriggerMode { TriggerMode(rawValue: d.string(forKey: triggerMode) ?? "") ?? .clickHold }
    static var live: LiveMode { LiveMode(rawValue: d.string(forKey: liveMode) ?? "") ?? .overlay }
    static var caret: CaretPlacement { CaretPlacement(rawValue: d.string(forKey: caretPlacement) ?? "") ?? .atPointer }
    static var hold: TimeInterval { d.double(forKey: holdDuration).clamped(to: holdDurationRange) }
    static var engine: SpeechEngine { SpeechEngine(rawValue: d.string(forKey: speechEngine) ?? "") ?? .apple }
    static var sounds: Bool { d.bool(forKey: playSounds) }
    static var thumbZone: Bool { d.bool(forKey: ignoreThumbZone) }
    /// Core Audio UID of the chosen microphone; empty means the system default.
    static var micUID: String { d.string(forKey: micUIDKey) ?? "" }
    static var locale: Locale {
        let id = d.string(forKey: localeID) ?? ""
        return id.isEmpty ? Locale.current : Locale(identifier: id)
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
