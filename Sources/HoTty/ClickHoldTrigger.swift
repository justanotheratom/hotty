import AppKit
import CoreGraphics

/// Receives hold events from either trigger. Always called on the main thread.
@MainActor
protocol HoldDelegate: AnyObject {
    /// A hold was recognized at `point` (CG coordinates). Return false to reject it.
    func holdBegan(at point: CGPoint, placeCaret: Bool) -> Bool
    /// The pointer moved during a recognized hold (for release gestures).
    func holdMoved(to point: CGPoint)
    func holdEnded()
    /// The hold turned out not to be one (rest-finger: a click before any speech); drop it silently.
    func holdCancelled()
}

/// Session state the trigger threads read without hopping to main.
final class SessionFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _busy = false
    private var _cancellable = false

    /// A session is listening or still finalizing; new holds pass through as clicks.
    var busy: Bool {
        get { lock.withLock { _busy } }
        set { lock.withLock { _busy = newValue } }
    }
    /// Nothing has been heard yet, so a click (rest-finger mode) may still call the hold off.
    var cancellable: Bool {
        get { lock.withLock { _cancellable } }
        set { lock.withLock { _cancellable = newValue } }
    }
}

/// Recognizes "press the trackpad and keep it down without moving" over a text field.
///
/// A mouse-down over editable text is held back. If the button comes up or the pointer
/// moves before the hold duration, the held event is replayed and the app sees a
/// normal (slightly delayed) click or drag. If the duration passes, the app never sees
/// the press at all, which keeps any selection under the pointer intact. From then on,
/// drags steer the release gesture (send or cancel) instead of reaching the app.
///
/// Runs on a dedicated thread so a busy main thread can't stall system input.
final class ClickHoldTrigger: @unchecked Sendable {
    private weak var delegate: HoldDelegate?
    private let flags: SessionFlags

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    // Tap-thread state.
    private enum State {
        case idle
        case pending(down: CGEvent)   // press held back, timer running
        case holding(down: CGEvent)   // recognized; press and release are swallowed
        case passthrough              // an ordinary press we let through, until release
    }
    private var state = State.idle
    private var timer: CFRunLoopTimer?

    private static let moveTolerance: CGFloat = 4
    private let hover = HoverCache()

    init(delegate: HoldDelegate, flags: SessionFlags) {
        self.delegate = delegate
        self.flags = flags
    }

    /// Installs the event tap. Fails without Accessibility permission.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = [CGEventType.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let me = Unmanaged<ClickHoldTrigger>.fromOpaque(refcon!).takeUnretainedValue()
            return me.handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(self.runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "hotty.clicktap"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        ready.wait()
        return true
    }

    func stop() {
        guard let tap else { return }
        perform {
            self.flushHeldPress()
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        self.tap = nil
        self.thread = nil
    }

    /// The delegate refused the hold: give the app its press back.
    func rejectHold() {
        perform {
            if case .holding(let down) = self.state {
                Synth.post(down)
                self.state = .passthrough
            }
        }
    }

    private func perform(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Event handling (tap thread)

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            flushHeldPress()
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == hottyEventTag { return pass }

        switch type {
        case .mouseMoved:
            hover.pointerMoved(to: event.location)
            return pass

        case .leftMouseDown:
            guard case .idle = state else { return pass }
            let isRepeatClick = event.getIntegerValueField(.mouseEventClickState) > 1
            if flags.busy || isRepeatClick || !hover.isEditable(at: event.location) {
                state = .passthrough
                return pass
            }
            guard let copy = event.copy() else { return pass }
            state = .pending(down: copy)
            startTimer()
            return nil

        case .leftMouseDragged:
            switch state {
            case .pending(let down) where moved(event, from: down):
                cancelTimer()
                replay(down, then: event)
                state = .passthrough
                return nil
            case .holding:
                // Once a hold is recognized, drags only steer the release gesture.
                let p = event.location
                DispatchQueue.main.async { [weak self] in self?.delegate?.holdMoved(to: p) }
                return nil
            case .pending:
                return nil
            case .idle, .passthrough:
                return pass
            }

        case .leftMouseUp:
            switch state {
            case .pending(let down):
                cancelTimer()
                replay(down, then: event)
                state = .idle
                return nil
            case .holding:
                state = .idle
                DispatchQueue.main.async { [weak self] in self?.delegate?.holdEnded() }
                return nil
            case .passthrough, .idle:
                state = .idle
                return pass
            }

        default:
            return pass
        }
    }

    private func moved(_ e: CGEvent, from down: CGEvent) -> Bool {
        hypot(e.location.x - down.location.x, e.location.y - down.location.y) > Self.moveTolerance
    }

    /// Re-posts the held press followed by `next`, preserving their order.
    private func replay(_ down: CGEvent, then next: CGEvent) {
        Synth.post(down)
        if let copy = next.copy() { Synth.post(copy) }
    }

    /// Makes sure a held-back press is never lost (tap disabled or stopped mid-press).
    private func flushHeldPress() {
        cancelTimer()
        switch state {
        case .pending(let down):
            Synth.post(down)
            state = .passthrough
        case .holding:
            state = .idle
            DispatchQueue.main.async { [weak self] in self?.delegate?.holdEnded() }
        default: break
        }
    }

    private func startTimer() {
        cancelTimer()
        let t = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + Pref.hold, 0, 0, 0) { [weak self] _ in
            self?.timerFired()
        }
        timer = t
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .commonModes)
    }

    private func cancelTimer() {
        if let timer { CFRunLoopTimerInvalidate(timer) }
        timer = nil
    }

    private func timerFired() {
        timer = nil
        guard case .pending(let down) = state else { return }
        state = .holding(down: down)
        let p = down.location
        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            if !delegate.holdBegan(at: p, placeCaret: true) { self.rejectHold() }
        }
    }
}

/// Answers "is the pointer over editable text?" fast enough to decide inside the event
/// tap. Hit-testing runs in the background as the pointer moves; a press that lands
/// somewhere not yet tested falls back to a synchronous check with a short timeout.
private final class HoverCache: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "hotty.hover", qos: .userInitiated)
    private var latest: CGPoint?
    private var scheduled = false
    private var result: (point: CGPoint, editable: Bool, at: CFAbsoluteTime)?

    func pointerMoved(to p: CGPoint) {
        lock.lock()
        latest = p
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 0.04) { [self] in
            let p: CGPoint? = lock.withLock { scheduled = false; return latest }
            guard let p else { return }
            let editable = AX.editableElement(at: p) != nil
            lock.withLock { result = (p, editable, CFAbsoluteTimeGetCurrent()) }
        }
    }

    func isEditable(at p: CGPoint) -> Bool {
        if let r = lock.withLock({ result }),
           hypot(r.point.x - p.x, r.point.y - p.y) < 2,
           CFAbsoluteTimeGetCurrent() - r.at < 1.5 {
            return r.editable
        }
        return AX.editableElement(at: p, timeout: 0.05) != nil
    }
}
