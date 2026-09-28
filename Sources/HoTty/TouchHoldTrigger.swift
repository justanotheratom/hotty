import AppKit

/// Recognizes "rest one finger on the trackpad without clicking or moving".
///
/// Uses the private MultitouchSupport framework (as BetterTouchTool does), loaded at
/// runtime so HoTty still launches if Apple changes or removes it.
///
/// One finger that stays still for the hold duration triggers; moving restarts the
/// clock, so "slide the pointer onto a field, then rest" works. If the rest turns out
/// to be a pause before a click (a click or further movement before any speech is
/// heard), the session is cancelled silently. A second finger aborts, and touches in
/// the bottom edge (where thumbs rest) can be ignored.
final class TouchHoldTrigger: @unchecked Sendable {
    private weak var delegate: HoldDelegate?
    private let flags: SessionFlags

    // Multitouch-thread state, guarded by `lock` since clicks arrive from main.
    private let lock = NSLock()
    private enum State {
        case idle
        /// Waiting for stillness. `since` is .infinity after a rejected hold, so it
        /// waits for the finger to move before trying again.
        case tracking(id: Int32, anchor: CGPoint, since: Double)
        case holding(id: Int32, anchor: CGPoint)
        case blocked   // ignore everything until all fingers lift
    }
    private var state = State.idle {
        didSet { if Self.debug, "\(oldValue)" != "\(state)" { NSLog("HoTty touch state → %@", "\(state)") } }
    }
    private var clickSeen = false

    private var devices: [UnsafeMutableRawPointer] = []
    private var clickMonitor: Any?

    private static let moveTolerance: Float = 0.015   // fraction of pad size
    private static let thumbZone: Float = 0.15         // bottom fraction of the pad

    /// The C callback can't capture context, so it reaches the live instance here.
    nonisolated(unsafe) fileprivate static var active: TouchHoldTrigger?

    init(delegate: HoldDelegate, flags: SessionFlags) {
        self.delegate = delegate
        self.flags = flags
    }

    static var isSupported: Bool { MT.api != nil }

    func start() -> Bool {
        guard let api = MT.api, devices.isEmpty else { return !devices.isEmpty }
        let list = api.createList().takeRetainedValue() as NSArray
        for case let dev as AnyObject in list {
            let ref = Unmanaged.passUnretained(dev).toOpaque()
            api.register(ref, touchCallback)
            api.start(ref, 0)
            devices.append(ref)
        }
        guard !devices.isEmpty else { return false }
        Self.active = self

        // Any physical click during a touch means the user is clicking, not dictating.
        // HoTty's own caret-placing click is tagged and ignored.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            guard e.cgEvent?.getIntegerValueField(.eventSourceUserData) != hottyEventTag else { return }
            self?.lock.withLock { self?.clickSeen = true }
        }
        return true
    }

    func stop() {
        guard let api = MT.api else { return }
        for dev in devices {
            api.unregister(dev, touchCallback)
            api.stop(dev)
        }
        devices.removeAll()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if Self.active === self { Self.active = nil }
        lock.withLock { state = .idle }
    }

    // MARK: - Frames (multitouch thread)

    /// Set HOTTY_DEBUG_TOUCH=1 to log raw contacts (state, position) for diagnosis.
    private static let debug = ProcessInfo.processInfo.environment["HOTTY_DEBUG_TOUCH"] != nil

    fileprivate func frame(_ touches: [MT.Touch], time: Double) {
        if Self.debug, !touches.isEmpty {
            NSLog("HoTty touch: %@", touches.map { "id=\($0.id) state=\($0.state) x=\($0.x) y=\($0.y)" }.joined(separator: " | "))
        }
        lock.lock()
        let touching = touches.filter(\.isTouching)
        let click = clickSeen
        clickSeen = false

        var event: (@MainActor () -> Void)?
        let single = touching.count == 1 ? touching.first : nil
        func moved(_ t: MT.Touch, from a: CGPoint) -> Bool {
            hypot(t.x - Float(a.x), t.y - Float(a.y)) > Self.moveTolerance
        }

        switch state {
        case .idle:
            if click { state = .blocked; break }
            guard let t = single else { break }
            if Pref.thumbZone, t.y < Self.thumbZone { state = .blocked; break }
            state = .tracking(id: t.id, anchor: t.point, since: time)

        case .tracking(let id, let anchor, let since):
            guard !click, let t = single, t.id == id else {
                state = touching.isEmpty && !click ? .idle : .blocked
                break
            }
            if moved(t, from: anchor) {
                state = .tracking(id: id, anchor: t.point, since: time)
            } else if time - since >= Pref.hold {
                if flags.busy {
                    state = .tracking(id: id, anchor: anchor, since: .infinity)
                    break
                }
                state = .holding(id: id, anchor: t.point)
                event = { [weak self] in
                    guard let self, let delegate = self.delegate else { return }
                    guard !delegate.holdBegan(at: ScreenGeometry.mouseCG, placeCaret: true) else { return }
                    self.lock.withLock {
                        if case .holding(let id, let anchor) = self.state {
                            self.state = .tracking(id: id, anchor: anchor, since: .infinity)
                        }
                    }
                }
            }

        case .holding(let id, let anchor):
            if touching.isEmpty {
                state = .idle
                event = { [weak self] in self?.delegate?.holdEnded() }
            } else if flags.cancellable, click || (single?.id == id && moved(single!, from: anchor)) {
                // Nothing said yet: this was a pause before clicking or moving on.
                state = .blocked
                event = { [weak self] in self?.delegate?.holdCancelled() }
            }

        case .blocked:
            if touching.isEmpty { state = .idle }
        }
        lock.unlock()
        if let event { DispatchQueue.main.async { MainActor.assumeIsolated { event() } } }
    }
}

private let touchCallback: MT.Callback = { _, data, count, timestamp, _ in
    guard let trigger = TouchHoldTrigger.active else { return 0 }
    var touches: [MT.Touch] = []
    if let data, count > 0 {
        for i in 0..<Int(count) { touches.append(MT.Touch(data + i * MT.Touch.stride)) }
    }
    trigger.frame(touches, time: timestamp)
    return 0
}

/// Minimal bindings for MultitouchSupport.framework.
private enum MT {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    struct API {
        let createList: @convention(c) () -> Unmanaged<CFArray>
        let register: @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
        let unregister: @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
        let start: @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        let stop: @convention(c) (UnsafeMutableRawPointer) -> Void
    }

    static let api: API? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let h = dlopen(path, RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            dlsym(h, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let createList = sym("MTDeviceCreateList", (@convention(c) () -> Unmanaged<CFArray>).self),
              let register = sym("MTRegisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, Callback) -> Void).self),
              let unregister = sym("MTUnregisterContactFrameCallback", (@convention(c) (UnsafeMutableRawPointer, Callback) -> Void).self),
              let start = sym("MTDeviceStart", (@convention(c) (UnsafeMutableRawPointer, Int32) -> Void).self),
              let stop = sym("MTDeviceStop", (@convention(c) (UnsafeMutableRawPointer) -> Void).self)
        else { return nil }
        return API(createList: createList, register: register, unregister: unregister, start: start, stop: stop)
    }()

    /// One contact, read from the framework's 96-byte MTTouch record by offset:
    /// frame@0, timestamp@8, pathIndex@16, state@20, fingerID@24, handID@28,
    /// normalized position x@32 y@36 (0…1, origin bottom-left), ...
    struct Touch {
        static let stride = 96
        let id: Int32
        let state: Int32
        let x: Float
        let y: Float

        init(_ p: UnsafeMutableRawPointer) {
            id = p.load(fromByteOffset: 16, as: Int32.self)
            state = p.load(fromByteOffset: 20, as: Int32.self)
            x = p.load(fromByteOffset: 32, as: Float.self)
            y = p.load(fromByteOffset: 36, as: Float.self)
        }

        var point: CGPoint { CGPoint(x: CGFloat(x), y: CGFloat(y)) }

        /// States 3 (make touch) and 4 (touching) mean the finger is on the surface.
        var isTouching: Bool { state == 3 || state == 4 }
    }
}
