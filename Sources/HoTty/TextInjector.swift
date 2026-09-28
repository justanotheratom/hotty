import AppKit
import CoreGraphics

/// Tag stamped on every event HoTty posts, so its own event tap lets them through.
let hottyEventTag: Int64 = 0x484F_5454_59   // "HOTTY"

enum Synth {
    static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = hottyEventTag
        return s
    }()

    static func post(_ e: CGEvent, tap: CGEventTapLocation = .cgSessionEventTap) {
        e.setIntegerValueField(.eventSourceUserData, value: hottyEventTag)
        e.post(tap: tap)
    }

    /// Posts a plain single click at `p` (CG coordinates) to place the caret.
    static func click(at p: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: p, mouseButton: .left) else { continue }
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            post(e)
        }
    }
}

/// Types text into whatever has keyboard focus using synthesized Unicode key events,
/// which bypass the keyboard layout and work in nearly every app.
///
/// All work runs on one serial queue. The injector remembers the volatile text it has
/// typed so far and moves the field to a new target with the fewest backspaces.
final class TextInjector {
    private let queue = DispatchQueue(label: "hotty.injector", qos: .userInteractive)

    // Queue-confined state.
    private var shownVolatile = ""   // volatile text currently typed into the field
    private var context: String?     // tail of the text before the insertion point; nil = unknown

    /// Starts a session. `textBefore` runs on the injector queue, before any typing,
    /// and returns the text preceding the caret ("" at the start of a field), or nil
    /// when the app doesn't expose it.
    func begin(textBefore: @escaping () -> String?) {
        queue.async {
            self.shownVolatile = ""
            self.context = textBefore()
        }
    }

    /// Inline mode: replace the currently shown volatile text with `text`.
    func showVolatile(_ text: String) {
        queue.async {
            let target = self.decorate(text)
            self.transition(from: self.shownVolatile, to: target)
            self.shownVolatile = target
        }
    }

    /// Commits a finalized phrase, replacing any shown volatile text.
    func commit(_ text: String) {
        queue.async {
            let target = self.decorate(text)
            self.transition(from: self.shownVolatile, to: target)
            self.shownVolatile = ""
            self.context = String(((self.context ?? "") + target).suffix(16))
        }
    }

    /// Removes any volatile text still shown (used on cancel).
    func clearVolatile() {
        queue.async {
            self.transition(from: self.shownVolatile, to: "")
            self.shownVolatile = ""
        }
    }

    /// Runs `block` after every queued keystroke has been posted.
    func flush(_ block: @escaping () -> Void) { queue.async(execute: block) }

    // MARK: - Spacing and capitalization

    private static let noSpaceBefore: Set<Character> = [".", ",", "!", "?", ";", ":", "'", ")", "]", "}", "%", "…"]
    private static let sentenceEnd: Set<Character> = [".", "!", "?", "\n"]

    /// Adds a leading space when joining onto existing text, and lowercases the first
    /// word when continuing mid-sentence (the recognizer capitalizes every segment).
    private func decorate(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = s.first, let ctx = context else { return s }

        if let prev = ctx.last, !prev.isWhitespace, !Self.noSpaceBefore.contains(first) {
            s = " " + s
        }
        let lastSolid = ctx.last { $0 != " " && $0 != "\t" }
        if let p = lastSolid, !Self.sentenceEnd.contains(p), first.isUppercase {
            let word = s.split(separator: " ").first.map(String.init) ?? ""
            let secondIsLower = word.dropFirst().first?.isLowercase ?? false
            if secondIsLower, word != "I", !word.hasPrefix("I'"), let i = s.firstIndex(of: first) {
                s.replaceSubrange(i...i, with: String(first).lowercased())
            }
        }
        return s
    }

    // MARK: - Keystrokes

    private func transition(from old: String, to new: String) {
        let common = old.commonPrefix(with: new).count
        let deletes = old.count - common
        let insert = String(new.dropFirst(common))
        if deletes > 0 { backspace(deletes) }
        if !insert.isEmpty { type(insert) }
    }

    private func backspace(_ n: Int) {
        for _ in 0..<n {
            key(51, down: true); key(51, down: false)   // kVK_Delete
            usleep(1500)
        }
    }

    private func type(_ s: String) {
        // CGEventKeyboardSetUnicodeString accepts at most 20 UTF-16 units per event;
        // split on character boundaries so emoji and accents stay intact.
        var chunk: [UniChar] = []
        func send() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: Synth.source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                Synth.post(e, tap: .cghidEventTap)
            }
            chunk.removeAll(keepingCapacity: true)
            usleep(3000)   // Electron and web views drop input that arrives too fast
        }
        for ch in s {
            let units = Array(String(ch).utf16)
            if chunk.count + units.count > 16 { send() }
            chunk += units
        }
        send()
    }

    private func key(_ code: CGKeyCode, down: Bool) {
        guard let e = CGEvent(keyboardEventSource: Synth.source, virtualKey: code, keyDown: down) else { return }
        e.flags = []
        Synth.post(e, tap: .cghidEventTap)
    }
}
