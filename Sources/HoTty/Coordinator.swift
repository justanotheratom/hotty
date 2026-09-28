import AppKit
import AVFoundation

/// Observable status for the menu bar and settings window.
@MainActor @Observable
final class AppState {
    var listening = false
    var accessibilityGranted = AX.isTrusted
    var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    var modelStatus = "Checking…"
    var triggerError: String?
}

/// Owns the active trigger and runs each dictation session:
/// hold → place caret or keep selection → listen → type → release → finalize.
@MainActor
final class Coordinator: HoldDelegate {
    let state = AppState()
    private let flags = SessionFlags()
    private let engine = DictationEngine()
    private let injector = TextInjector()
    private let overlay = OverlayController()

    private var click: ClickHoldTrigger?
    private var touch: TouchHoldTrigger?
    private var activeTrigger: TriggerMode?

    private enum Phase { case idle, listening, finishing }
    private var phase = Phase.idle
    private var session = 0
    private var live = LiveMode.overlay
    private var pendingVolatile = ""   // volatile text not yet replaced by a final result

    init() {
        engine.onStatusChange = { [weak self] in
            guard let self else { return }
            self.state.modelStatus = self.engine.modelStatus
        }
    }

    // MARK: - Setup

    func refreshPermissions() {
        state.accessibilityGranted = AX.isTrusted
        state.microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Starts the trigger chosen in settings, stopping the other one.
    func applyTrigger() {
        let mode = Pref.trigger
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

    // MARK: - HoldDelegate

    func holdBegan(at p: CGPoint, placeCaret: Bool) -> Bool {
        guard phase == .idle, state.microphone == .authorized,
              let target = AX.editableElement(at: p) else {
            NSLog("HoTty hold rejected at %@: phase=%@ mic=%d editable=%d", "\(p)", "\(phase)",
                  state.microphone.rawValue, AX.editableElement(at: p) != nil ? 1 : 0)
            return false
        }

        let overSelection = AX.selectionContains(target, p)
        if overSelection {
            // Replace the selection: focus without clicking so it survives.
            if !isFocused(target) { AX.focus(target) }
        } else if Pref.caret == .atPointer || !isFocused(target) {
            Synth.click(at: p)
        }

        session += 1
        let id = session
        live = Pref.live
        pendingVolatile = ""
        let cb = DictationEngine.Callbacks(
            volatile: { [weak self] s in self?.onVolatile(s, session: id) },
            final: { [weak self] s in self?.onFinal(s, session: id) },
            level: { [weak self] l in if self?.session == id { self?.overlay.setLevel(l) } },
            interrupted: { [weak self] in
                // Keep what was said so far, as if the user had let go.
                if self?.session == id { self?.holdEnded() }
            }
        )
        do {
            try engine.start(cb)
        } catch {
            NSLog("HoTty: couldn't start audio: \(error)")
            return false
        }

        phase = .listening
        flags.busy = true
        flags.cancellable = true
        state.listening = true
        // Read the text before the caret once the app has handled our click.
        injector.begin { usleep(80_000); return AX.textBeforeCaret() }
        overlay.show(at: p)
        play("Tink")
        return true
    }

    func holdEnded() {
        guard phase == .listening else { return }
        phase = .finishing
        overlay.finishing()
        play("Pop")
        let id = session
        Task {
            await engine.finish()
            guard id == session else { return }
            // Anything the recognizer never finalized still gets typed.
            if !pendingVolatile.isEmpty { injector.commit(pendingVolatile) }
            pendingVolatile = ""
            injector.flush { DispatchQueue.main.async { self.endSession(id) } }
        }
    }

    func holdCancelled() {
        guard phase == .listening else { return }
        engine.cancel()
        injector.clearVolatile()
        endSession(session)
    }

    // MARK: - Results

    private func onVolatile(_ s: String, session id: Int) {
        guard id == session, phase != .idle else { return }
        flags.cancellable = false
        pendingVolatile = s
        switch live {
        case .overlay: overlay.setText(s)
        case .inline: injector.showVolatile(s)
        }
    }

    private func onFinal(_ s: String, session id: Int) {
        guard id == session, phase != .idle else { return }
        flags.cancellable = false
        pendingVolatile = ""
        injector.commit(s)
        if live == .overlay { overlay.setText("") }
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

    /// HOTTY_AUDIO_TEST=1: three start/finish cycles on the current input device, logged.
    func audioSelfTest(round: Int = 0) {
        guard round < 3 else { NSLog("HoTty audio test: done"); return }
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
