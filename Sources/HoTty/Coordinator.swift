import AppKit
import AVFoundation
import Speech

/// Observable status for the menu bar and settings window.
@MainActor @Observable
final class AppState {
    var listening = false
    var accessibilityGranted = AX.isTrusted
    var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    var speech = SFSpeechRecognizer.authorizationStatus()
    var modelStatus = "Checking…"
    var model = DictationEngine.ModelState.checking
    var triggerError: String?
    var micName = Microphones.currentName()

    /// Something stops dictation from working at all.
    var needsAttention: Bool { !accessibilityGranted || microphone != .authorized }
}

/// Owns the active trigger and runs each dictation session:
/// hold → place caret or keep selection → listen → type → release → finalize.
/// Dragging up before release locks the session into hands-free mode, which then ends
/// only from the overlay's Cancel / Finish / Send buttons.
@MainActor
final class Coordinator: HoldDelegate {
    let state = AppState()
    private let flags = SessionFlags()
    private let engine = DictationEngine()
    private let injector = TextInjector()
    private let overlay = OverlayController()
    let store = Store.shared

    private var click: ClickHoldTrigger?
    private var touch: TouchHoldTrigger?
    private var activeTrigger: TriggerMode?

    private enum Phase { case idle, listening, locked, finishing, practice }
    private var phase = Phase.idle
    private var session = 0
    private var live = LiveMode.overlay
    private var pendingVolatile = ""   // volatile text not yet replaced by a final result
    private var anchor = CGPoint.zero   // where the hold began; release gestures are measured from here
    private var action = ReleaseAction.finish
    private var focusPoll: Timer?       // hands-free: resumes typing when the field regains focus
    private var pauseTimer: Timer?

    // What the current session typed, for History.
    private var sessionText = ""
    private var sessionStart = Date()
    private var sessionApp: NSRunningApplication?

    /// How far (points) the pointer must travel for a release gesture.
    private static let gestureDistance: CGFloat = 60
    /// Movement (points) after which the overlay hints at the gestures.
    private static let hintDistance: CGFloat = 15

    init() {
        engine.onStatusChange = { [weak self] in
            guard let self else { return }
            self.state.modelStatus = self.engine.modelStatus
            self.state.model = self.engine.model
        }
        engine.contextualWords = { Store.shared.words }
        overlay.onButton = { [weak self] action in self?.lockedButton(action) }
    }

    // MARK: - Setup

    func refreshPermissions() {
        state.accessibilityGranted = AX.isTrusted
        state.microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        state.speech = SFSpeechRecognizer.authorizationStatus()
        let mic = Microphones.currentName()
        if state.micName != mic { state.micName = mic }
    }

    /// Starts the trigger chosen in settings, stopping the other one.
    func applyTrigger() {
        let mode = Pref.trigger
        pauseTimer?.invalidate()
        if store.isPaused, let until = store.pausedUntil {
            // Paused: no trigger at all, so presses reach apps without any delay.
            click?.stop(); click = nil
            touch?.stop(); touch = nil
            activeTrigger = nil
            state.triggerError = nil
            pauseTimer = Timer.scheduledTimer(withTimeInterval: max(1, until.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
            return
        }
        guard mode != activeTrigger || state.triggerError != nil else { return }
        click?.stop(); click = nil
        touch?.stop(); touch = nil
        activeTrigger = nil
        state.triggerError = nil

        guard AX.isTrusted else {
            state.triggerError = "Waiting for Accessibility permission."
            return
        }
        switch mode {
        case .clickHold:
            let t = ClickHoldTrigger(delegate: self, flags: flags)
            if t.start() { click = t; activeTrigger = mode }
            else { state.triggerError = "Couldn't install the event tap." }
        case .touchHold:
            let t = TouchHoldTrigger(delegate: self, flags: flags)
            if t.start() { touch = t; activeTrigger = mode }
            else { state.triggerError = TouchHoldTrigger.isSupported ? "No trackpad found." : "Multitouch framework unavailable on this macOS." }
        }
    }

    func ensureModel() { Task { await engine.ensureModel() } }

    // MARK: - Pause

    func pause(for seconds: TimeInterval = 3600) {
        store.pause(for: seconds)
        applyTrigger()
    }

    func resume() {
        store.resume()
        applyTrigger()
    }

    /// Puts the most recent dictation on the clipboard.
    func copyLast() {
        guard let d = store.last else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.text, forType: .string)
    }

    // MARK: - HoldDelegate

    func holdBegan(at p: CGPoint, placeCaret: Bool) -> Bool {
        guard !store.isPaused else { return false }
        if phase == .idle, case .downloading(let f) = state.model {
            overlay.notice("Speech model downloading · \(Int(f * 100))%", at: p, progress: f)
            return false
        }
        if phase == .idle, case .preparing(let s) = state.model {
            overlay.notice(s, at: p)
            return false
        }
        guard phase == .idle, state.microphone == .authorized,
              let target = AX.editableElement(at: p) else {
            NSLog("HoTty hold rejected at %@: phase=%@ mic=%d editable=%d", "\(p)", "\(phase)",
                  state.microphone.rawValue, AX.editableElement(at: p) != nil ? 1 : 0)
            return false
        }

        // Remember any selection typing will replace, so cancel can restore it.
        var replacedSelection = ""
        if AX.selectionContains(target, p) {
            // Replace the selection: focus without clicking so it survives.
            if !isFocused(target) { AX.focus(target) }
            replacedSelection = AX.selectedText(target)
        } else if Pref.caret == .atPointer || !isFocused(target) {
            Synth.click(at: p)
        } else {
            replacedSelection = AX.selectedText(target)
        }

        session += 1
        let id = session
        sessionText = ""
        sessionStart = Date()
        sessionApp = NSWorkspace.shared.frontmostApplication
        live = Pref.live
        pendingVolatile = ""
        anchor = p
        action = .finish
        let cb = DictationEngine.Callbacks(
            volatile: { [weak self] s in self?.onVolatile(s, session: id) },
            final: { [weak self] s in self?.onFinal(s, session: id) },
            level: { [weak self] l in if self?.session == id { self?.overlay.setLevel(l) } },
            interrupted: { [weak self] in
                // Keep what was said so far, as if the user had let go.
                NSLog("HoTty: audio device changed mid-session")
                if self?.session == id { self?.finish(pressReturn: false) }
            }
        )
        do {
            try engine.start(cb)
        } catch {
            NSLog("HoTty: couldn't start audio: \(error)")
            if case DictationEngine.EngineError.noMicrophone = error {
                overlay.notice("No microphone. Plug one in or pick another in Settings.", at: p)
            } else if case DictationEngine.EngineError.phononNotReady = error {
                overlay.notice(error.localizedDescription, at: p)
            }
            return false
        }

        phase = .listening
        flags.busy = true
        flags.cancellable = true
        state.listening = true
        // Read the text before the caret once the app has handled our click.
        injector.begin(selection: replacedSelection) { usleep(80_000); return AX.textBeforeCaret() }
        overlay.show(at: p)
        play("Tink")
        return true
    }

    /// Dragging picks what releasing will do: right sends (adds Return), left cancels,
    /// up locks into hands-free mode. Diagonal movement counts for its dominant direction.
    func holdMoved(to p: CGPoint) {
        guard phase == .listening else { return }
        let dx = p.x - anchor.x, dy = p.y - anchor.y   // CG coordinates: y grows downward
        if hypot(dx, dy) > Self.hintDistance { overlay.setHint(true) }
        let new: ReleaseAction
        if abs(dy) > abs(dx) {
            new = -dy >= Self.gestureDistance ? .lock : .finish
        } else if abs(dx) >= Self.gestureDistance {
            new = dx > 0 ? .send : .cancel
        } else {
            new = .finish
        }
        guard new != action else { return }
        action = new
        overlay.setAction(new)
        if new != .finish { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    func holdEnded() {
        guard phase == .listening else { return }
        switch action {
        case .finish: finish(pressReturn: false)
        case .send: finish(pressReturn: true)
        case .cancel: cancelAndRevert()
        case .lock: lock()
        }
    }

    /// A click before any speech (rest-finger mode): the rest was a pause, not a hold.
    func holdCancelled() {
        guard phase == .listening else { return }
        cancelAndRevert(sound: false)
    }

    // MARK: - Hands-free

    /// Keeps listening after release. From here on HoTty ignores gestures and keys (new
    /// holds pass through as clicks while `flags.busy`), and only the overlay buttons end it.
    private func lock() {
        phase = .locked
        store.markDone(.free)
        flags.cancellable = false
        // In-progress words move to the overlay: typing and backspacing them live could
        // land in another app the moment focus moves. Final phrases are still typed.
        if live == .inline { injector.showVolatile("") }
        live = .overlay
        overlay.setText(pendingVolatile)
        overlay.setLocked(true)
        play("Morse")
        focusPoll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .locked else { return }
                self.injector.resumeIfFocused()
                self.overlay.setWaiting(self.injector.waitingWords)
            }
        }
    }

    private func lockedButton(_ action: ReleaseAction) {
        guard phase == .locked else { return }
        switch action {
        case .cancel: cancelAndRevert()
        case .send: finish(pressReturn: true)
        case .finish, .lock: finish(pressReturn: false)
        }
    }

    // MARK: - Ending

    private func finish(pressReturn: Bool) {
        guard phase == .listening || phase == .locked else { return }
        if ProcessInfo.processInfo.environment["HOTTY_LOCK_TEST"] != nil {
            NSLog("HoTty session: finish(pressReturn: %d) from phase %@", pressReturn ? 1 : 0, "\(phase)")
        }
        let wasLocked = phase == .locked
        let spoke = Date().timeIntervalSince(sessionStart)
        phase = .finishing
        stopFocusPoll()
        overlay.finishing()
        play(pressReturn ? "Glass" : "Pop")
        let id = session
        Task {
            // Finishing from the overlay while elsewhere: bring the field back first.
            if wasLocked, injector.waitingWords > 0, let target = injector.targetElement {
                AX.focus(target)
                try? await Task.sleep(for: .milliseconds(250))
            }
            await engine.finish()
            guard id == session else { return }
            // Anything the recognizer never finalized still gets typed.
            if !pendingVolatile.isEmpty {
                injector.commit(pendingVolatile)
                appendSession(pendingVolatile)
            }
            pendingVolatile = ""
            injector.finish(pressReturn: pressReturn) { leftover in
                self.recordSession(sent: pressReturn && leftover == nil, seconds: spoke)
                guard let leftover else { return self.endSession(id) }
                // The field never came back (closed, navigated away): don't lose the words.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(leftover, forType: .string)
                self.overlay.flash("Copied to clipboard")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.endSession(id) }
            }
        }
    }

    /// Stops listening and puts the field back as it was before the hold.
    private func cancelAndRevert(sound: Bool = true) {
        if ProcessInfo.processInfo.environment["HOTTY_LOCK_TEST"] != nil { NSLog("HoTty session: cancel from phase %@", "\(phase)") }
        stopFocusPoll()
        engine.cancel()
        injector.revert()
        if sound { play("Bottle") }
        endSession(session)
    }

    private func stopFocusPoll() {
        focusPoll?.invalidate()
        focusPoll = nil
    }

    // MARK: - Results

    private func onVolatile(_ raw: String, session id: Int) {
        guard id == session, phase != .idle, phase != .practice else { return }
        let s = store.transform(raw)
        flags.cancellable = false
        pendingVolatile = s
        switch live {
        case .overlay: overlay.setText(s)
        case .inline: injector.showVolatile(s)
        }
    }

    private func onFinal(_ raw: String, session id: Int) {
        guard id == session, phase != .idle, phase != .practice else { return }
        let s = store.transform(raw)
        flags.cancellable = false
        pendingVolatile = ""
        injector.commit(s)
        appendSession(s)
        if live == .overlay { overlay.setText("") }
    }

    private func appendSession(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        if sessionText.isEmpty || t.first.map({ ".,!?;:".contains($0) || $0.isNewline }) == true || sessionText.last?.isNewline == true {
            sessionText += t
        } else {
            sessionText += " " + t
        }
    }

    private func recordSession(sent: Bool, seconds: TimeInterval) {
        let text = sessionText.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionText = ""
        guard !text.isEmpty else { return }
        if sent { store.markDone(.send) }
        store.record(Dictation(date: sessionStart, app: sessionApp?.localizedName ?? "Unknown app",
                               bundleID: sessionApp?.bundleIdentifier, text: text, sent: sent, seconds: seconds))
    }

    // MARK: - Practice (onboarding)

    /// Dictation into the onboarding practice box: real speech recognition, but nothing
    /// is typed into other apps and nothing is recorded in History.
    struct PracticeCallbacks {
        var text: (String) -> Void
        var level: (Float) -> Void
    }
    private var practiceCommitted = ""

    func practiceStart(_ cb: PracticeCallbacks) -> String? {
        guard phase == .idle else { return "HoTty is busy with another dictation." }
        guard state.microphone == .authorized else { return "Allow the microphone first (step 2)." }
        if case .downloading(let f) = state.model { return "The speech model is still downloading (\(Int(f * 100))%)." }
        if case .preparing(let s) = state.model { return s }
        session += 1
        let id = session
        practiceCommitted = ""
        let join = { (a: String, b: String) -> String in
            let b = b.trimmingCharacters(in: .whitespaces)
            if a.isEmpty || b.isEmpty { return a + b }
            return ".,!?".contains(b.first!) ? a + b : a + " " + b
        }
        let engineCB = DictationEngine.Callbacks(
            volatile: { [weak self] s in
                guard let self, self.session == id else { return }
                cb.text(join(self.practiceCommitted, self.store.transform(s)))
            },
            final: { [weak self] s in
                guard let self, self.session == id else { return }
                self.practiceCommitted = join(self.practiceCommitted, self.store.transform(s))
                cb.text(self.practiceCommitted)
            },
            level: { l in cb.level(l) },
            interrupted: {}
        )
        do { try engine.start(engineCB) } catch { return error.localizedDescription }
        phase = .practice
        flags.busy = true
        state.listening = true
        play("Tink")
        return nil
    }

    /// Ends practice and returns everything recognized.
    func practiceFinish(send: Bool) async -> String {
        guard phase == .practice else { return "" }
        play(send ? "Glass" : "Pop")
        await engine.finish()
        phase = .idle
        flags.busy = false
        state.listening = false
        return practiceCommitted
    }

    func practiceCancel() {
        guard phase == .practice else { return }
        engine.cancel()
        play("Bottle")
        phase = .idle
        flags.busy = false
        state.listening = false
    }

    private func endSession(_ id: Int) {
        guard id == session else { return }
        phase = .idle
        flags.busy = false
        flags.cancellable = false
        state.listening = false
        overlay.hide()
    }

    /// HOTTY_OVERLAY_DEMO=1: runs several fake sessions back to back (overlay, level
    /// meter, menu bar icon) at dictation speed, for tuning the look and stress-testing layout.
    func demoOverlay(round: Int = 0) {
        guard round < 6 else { return }
        let f = NSScreen.main?.frame ?? .zero
        let modeOverlay = round % 2 == 0
        state.listening = true
        overlay.show(at: CGPoint(x: f.midX - 150 + CGFloat(round * 30), y: f.midY - 60))
        let words = "Hello there, this is a quick test of hold to talk dictation, and it keeps going with a longer sentence".split(separator: " ")
        for i in 0...words.count where modeOverlay {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(i) * 0.08) {
                self.overlay.setText(words.prefix(i).joined(separator: " "))
            }
        }
        for i in 0..<100 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.025) {
                self.overlay.setLevel(Float(abs(sin(Double(i) / 5))))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.overlay.setAction([ReleaseAction.finish, .send, .cancel][round % 3])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            self.overlay.setText("")
            self.overlay.finishing()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            self.overlay.hide()
            self.state.listening = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.demoOverlay(round: round + 1) }
        }
    }

    /// HOTTY_GESTURE_TEST=1: in the focused text field, replaces a selection then cancels
    /// (text and selection should come back), then dictates at the end and sends (adds Return).
    func gestureSelfTest() {
        func log(_ step: String) {
            guard let el = AX.focusedElement else { return NSLog("HoTty gesture test %@: no focus", step) }
            let value: String = AX.attr(el, kAXValueAttribute) ?? "?"
            NSLog("HoTty gesture test %@: value=%@ selected=%@", step, value.debugDescription, AX.selectedText(el).debugDescription)
        }
        // This test types into the focused field, so it must never touch anything but TextEdit.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit",
              let el = AX.focusedElement, AX.pid(el) == NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return NSLog("HoTty gesture test: aborted, TextEdit is not the focused app") }
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, "Hello world, testing." as CFString)
        var r = CFRange(location: 6, length: 5)
        AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
        log("start")
        injector.begin(selection: AX.selectedText(el)) { AX.textBeforeCaret() }
        injector.commit("Brave new")
        // The app handles posted keystrokes asynchronously; give it a moment before reading.
        injector.flush { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            log("typed")
            self.injector.revert()
            self.injector.flush { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                log("cancelled")
                let v: String = AX.attr(el, kAXValueAttribute) ?? ""
                var end = CFRange(location: v.utf16.count, length: 0)
                AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &end)!)
                self.injector.begin(selection: "") { AX.textBeforeCaret() }
                self.injector.commit("Line two")
                self.injector.finish(pressReturn: true) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { log("sent") }
                }
            } }
        } }
    }

    /// HOTTY_LOCK_TEST=1: in a focused TextEdit document, runs a hands-free session with
    /// simulated recognition: lock, type a phrase, switch to Finder (a phrase arrives and
    /// must wait), then clicks the overlay's real Finish button, which must bring TextEdit
    /// back and type the waiting phrase.
    func lockSelfTest() {
        func value() -> String {
            AX.focusedElement.flatMap { AX.attr($0, kAXValueAttribute) as String? } ?? "?"
        }
        guard let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == "com.apple.TextEdit",
              let field = AX.focusedElement, AX.pid(field) == front.processIdentifier, let frame = AX.frame(field)
        else { return NSLog("HoTty lock test: aborted, TextEdit is not the focused app") }
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, "Start." as CFString)
        let p = CGPoint(x: frame.minX + 200, y: frame.minY + 40)
        guard holdBegan(at: p, placeCaret: true) else { return NSLog("HoTty lock test: hold rejected") }
        holdMoved(to: CGPoint(x: p.x + 5, y: p.y - 80))
        holdEnded()
        NSLog("HoTty lock test: phase after release = %@", "\(phase)")
        let id = session
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.onFinal("Typed while focused.", session: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSLog("HoTty lock test: TextEdit value = %@", value().debugDescription)
                NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.finder" }?.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.onFinal("Said while away.", session: id)
                    NSLog("HoTty lock test: away phrase delivered")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        NSLog("HoTty lock test: frontmost = %@, waiting words = %d",
                              NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", self.injector.waitingWords)
                        self.clickOwnButton("Finish") {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                NSLog("HoTty lock test: after Finish, frontmost = %@, phase = %@, value = %@",
                                      NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", "\(self.phase)",
                                      value().debugDescription)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Finds one of HoTty's own overlay buttons through Accessibility (off the main
    /// thread, which has to answer the query) and clicks it with a real mouse event.
    private func clickOwnButton(_ title: String, then: @escaping () -> Void) {
        DispatchQueue.global().async {
            let app = AXUIElementCreateApplication(AX.ownPID)
            var found: CGRect?
            func search(_ el: AXUIElement, depth: Int) {
                guard found == nil, depth < 12 else { return }
                let role: String? = AX.attr(el, kAXRoleAttribute)
                let label: String = AX.attr(el, kAXTitleAttribute) ?? AX.attr(el, kAXDescriptionAttribute) ?? ""
                if role == kAXButtonRole, label.contains(title) { found = AX.frame(el); return }
                for c in (AX.attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { search(c, depth: depth + 1) }
            }
            for w in (AX.attr(app, kAXWindowsAttribute) as [AXUIElement]?) ?? [] { search(w, depth: 0) }
            guard let r = found else {
                NSLog("HoTty lock test: %@ button not found", title)
                return DispatchQueue.main.async(execute: then)
            }
            let c = CGPoint(x: r.midX, y: r.midY)
            NSLog("HoTty lock test: clicking %@ at %@", title, "\(c)")
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(300_000)   // let the overlay notice the pointer and start accepting clicks
            for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(50_000)
            }
            DispatchQueue.main.async(execute: then)
        }
    }

    /// HOTTY_AUDIO_TEST=1: three start/finish cycles on the current input device, logged.
    func audioSelfTest(round: Int = 0) {
        guard round < 3 else { NSLog("HoTty audio test: done"); return }
        guard state.model == .ready else {
            // Phonon takes a few seconds to load; test once the engine can take audio.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.audioSelfTest(round: round) }
            return
        }
        var levels = 0
        let cb = DictationEngine.Callbacks(
            volatile: { NSLog("HoTty audio test: volatile %@", $0) },
            final: { NSLog("HoTty audio test: final %@", $0) },
            level: { _ in levels += 1 },
            interrupted: { NSLog("HoTty audio test: interrupted") }
        )
        do {
            try engine.start(cb)
        } catch {
            NSLog("HoTty audio test %d: start failed: %@", round, "\(error)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task {
                await self.engine.finish()
                NSLog("HoTty audio test %d: ok, %d level callbacks", round, levels)
                self.audioSelfTest(round: round + 1)
            }
        }
    }

    // MARK: - Helpers

    private func isFocused(_ el: AXUIElement) -> Bool {
        guard let f = AX.focusedElement else { return false }
        return CFEqual(f, el)
    }

    private func play(_ name: String) {
        guard Pref.sounds else { return }
        NSSound(named: name)?.play()
    }
}
