import AppKit
import Foundation

/// One finished dictation, as listed in History.
struct Dictation: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var app: String
    var bundleID: String?
    var text: String
    var sent: Bool
    /// From the start of listening to letting go (or pressing Finish), for words per minute.
    var seconds: Double

    var words: Int { Store.wordCount(text) }
}

/// "When HoTty hears `say`, it types `type`."
struct Replacement: Codable, Identifiable, Hashable {
    var id = UUID()
    var say: String
    var type: String
}

/// Get-started checklist items that finish on their own when the user does them.
enum Task4: String, Codable, CaseIterable, Identifiable {
    case free, send, word, login
    var id: String { rawValue }
}

/// Everything HoTty remembers besides preferences: dictation history, custom words,
/// replacements, checklist progress and the pause. Kept as one JSON file in
/// Application Support; nothing leaves the Mac.
@MainActor @Observable
final class Store {
    static let shared = Store()

    private(set) var history: [Dictation] = []
    private(set) var words: [String] = []
    private(set) var replacements: [Replacement] = []
    private(set) var tasksDone: Set<Task4> = []
    /// Highest What's new entry the user has opened.
    private(set) var newsSeen = 0
    private(set) var pausedUntil: Date?

    static let latestNews = 4

    private struct Saved: Codable {
        var history: [Dictation] = []
        var words: [String] = []
        var replacements: [Replacement] = []
        var tasksDone: [Task4] = []
        var newsSeen = 0
        var pausedUntil: Date?
    }

    private static let defaultWords = ["HoTty", "Eightinity", "SwiftUI", "SpeechAnalyzer", "Kubernetes"]
    private static let defaultReplacements = [
        Replacement(say: "new line", type: "\n"),
        Replacement(say: "new paragraph", type: "\n\n"),
        Replacement(say: "eight infinity", type: "Eightinity"),
    ]
    private static let historyLimit = 2000

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HoTty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url), let s = try? JSONDecoder.iso.decode(Saved.self, from: data) {
            history = s.history
            words = s.words
            replacements = s.replacements
            tasksDone = Set(s.tasksDone)
            newsSeen = s.newsSeen
            pausedUntil = s.pausedUntil
        } else {
            words = Self.defaultWords
            replacements = Self.defaultReplacements
            save()
        }
        rebuildMatchers()
    }

    private func save() {
        let s = Saved(history: history, words: words, replacements: replacements,
                      tasksDone: Array(tasksDone), newsSeen: newsSeen, pausedUntil: pausedUntil)
        guard let data = try? JSONEncoder.iso.encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - History

    func record(_ d: Dictation) {
        guard !d.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        history.insert(d, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    func delete(_ d: Dictation) {
        history.removeAll { $0.id == d.id }
        save()
    }

    var last: Dictation? { history.first }

    // MARK: - Stats

    enum Range: Hashable { case today, week, all }

    struct Stats {
        var wpm: Int?
        var words: Int
        var savedMinutes: Double
        var apps: Int
    }

    func stats(_ range: Range, now: Date = Date()) -> Stats {
        let cal = Calendar.current
        let items = history.filter { d in
            switch range {
            case .today: cal.isDate(d.date, inSameDayAs: now)
            case .week: cal.isDate(d.date, equalTo: now, toGranularity: .weekOfYear)
            case .all: true
            }
        }
        let words = items.reduce(0) { $0 + $1.words }
        let minutes = items.reduce(0) { $0 + $1.seconds } / 60
        // A few seconds of talking gives a meaningless rate; wait for some real use.
        let wpm = minutes >= 0.25 && words >= 10 ? Int((Double(words) / minutes).rounded()) : nil
        let saved = max(0, Double(words) / 40 - minutes)
        return Stats(wpm: wpm, words: words, savedMinutes: saved, apps: Set(items.map(\.app)).count)
    }

    nonisolated static func wordCount(_ s: String) -> Int {
        s.split { $0.isWhitespace || $0.isNewline }.filter { $0.contains { $0.isLetter || $0.isNumber } }.count
    }

    // MARK: - Vocabulary

    @discardableResult
    func addWord(_ w: String) -> Bool {
        let w = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !words.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return false }
        words.append(w)
        tasksDone.insert(.word)
        rebuildMatchers()
        save()
        return true
    }

    func removeWord(_ w: String) {
        words.removeAll { $0 == w }
        rebuildMatchers()
        save()
    }

    func addReplacement(say: String, type: String) {
        let say = say.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !say.isEmpty, !type.isEmpty else { return }
        replacements.removeAll { $0.say.caseInsensitiveCompare(say) == .orderedSame }
        replacements.append(Replacement(say: say, type: type))
        rebuildMatchers()
        save()
    }

    func removeReplacement(_ r: Replacement) {
        replacements.removeAll { $0.id == r.id }
        rebuildMatchers()
        save()
    }

    /// Compiled once per change; `transform` runs on every recognized phrase.
    @ObservationIgnored private var wordMatchers: [(NSRegularExpression, String)] = []
    @ObservationIgnored private var replacementMatchers: [(NSRegularExpression, String)] = []

    private func rebuildMatchers() {
        wordMatchers = words.compactMap { w in
            // "SwiftUI" may come back as "swift ui", "HoTty" as "hotty": match the word's
            // parts in any case, with optional spaces where the case or letters/digits change.
            let parts = Self.splitParts(w).map(NSRegularExpression.escapedPattern(for:))
            guard !parts.isEmpty else { return nil }
            let pattern = "(?<![\\p{L}\\p{N}])" + parts.joined(separator: "[\\s-]?") + "(?![\\p{L}\\p{N}])"
            return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, w) }
        }
        replacementMatchers = replacements.compactMap { r in
            let phrase = r.say.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "[\\s,]+")
            // A spoken command like "new line" often comes back with a period after it.
            let tail = r.type.allSatisfy(\.isWhitespace) ? "[.,]?[ \\t]*" : ""
            let pattern = "[ \\t]*(?<![\\p{L}\\p{N}])" + phrase + "(?![\\p{L}\\p{N}])" + tail
            let template = NSRegularExpression.escapedTemplate(for: r.type.allSatisfy(\.isWhitespace) ? r.type : " " + r.type)
            return (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, template) }
        }
    }

    private static func splitParts(_ w: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var prev: Character?
        for ch in w {
            if let p = prev, !cur.isEmpty,
               (p.isLowercase && ch.isUppercase) || (p.isLetter && ch.isNumber) || (p.isNumber && ch.isLetter) || ch == " " || ch == "-" {
                parts.append(cur); cur = ""
            }
            if ch != " " && ch != "-" { cur.append(ch) }
            prev = ch
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts
    }

    /// Applies custom spellings and replacements to recognized text.
    func transform(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        var out = s
        for (re, template) in replacementMatchers {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        for (re, word) in wordMatchers {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: word))
        }
        if out.hasPrefix(" ") && !s.hasPrefix(" ") { out.removeFirst() }
        return out
    }

    // MARK: - Checklist, news, pause

    func markDone(_ t: Task4) {
        guard !tasksDone.contains(t) else { return }
        tasksDone.insert(t)
        save()
    }

    func markNewsSeen() {
        guard newsSeen < Self.latestNews else { return }
        newsSeen = Self.latestNews
        save()
    }

    var newsUnread: Bool { newsSeen < Self.latestNews }

    var isPaused: Bool {
        guard let p = pausedUntil else { return false }
        return p > Date()
    }

    func pause(for seconds: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(seconds)
        save()
    }

    func resume() {
        pausedUntil = nil
        save()
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// "Just now", "18 min ago", "3 h ago", "Yesterday", "Sep 12".
func relativeWhen(_ d: Date, now: Date = Date()) -> String {
    let s = now.timeIntervalSince(d)
    let cal = Calendar.current
    if s < 60 { return "Just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if cal.isDate(d, inSameDayAs: now) { return "\(Int(s / 3600)) h ago" }
    if cal.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(.dateTime.month(.abbreviated).day())
}

/// "0 min", "12 min", "1 h 5 min".
func minutesLabel(_ m: Double) -> String {
    let total = Int(m.rounded())
    if total < 60 { return "\(total) min" }
    return total % 60 == 0 ? "\(total / 60) h" : "\(total / 60) h \(total % 60) min"
}
