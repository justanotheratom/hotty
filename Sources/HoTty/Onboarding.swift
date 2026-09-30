import AVFoundation
import ServiceManagement
import Speech
import SwiftUI

/// First-run setup: permissions, hold style, gestures, language, a practice box, done.
struct OnboardingView: View {
    let coordinator: Coordinator
    let windows: Windows
    @State private var step = 0
    @State private var practiced: Set<PracticeResult> = []

    private static let count = 8
    private var state: AppState { coordinator.state }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: WelcomeStep()
                case 1: VoiceStep(coordinator: coordinator)
                case 2: AccessStep(coordinator: coordinator)
                case 3: HoldStep()
                case 4: GesturesStep()
                case 5: LanguageStep(coordinator: coordinator)
                case 6: TryStep(coordinator: coordinator, done: $practiced)
                default: DoneStep(coordinator: coordinator)
                }
            }
            .padding(.horizontal, 64)
            .padding(.top, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(step)
            .transition(.opacity)

            footer
        }
        .frame(width: 720, height: 540)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .onAppear { coordinator.refreshPermissions() }
    }

    private var footer: some View {
        HStack {
            Button("Back") { go(step - 1) }
                .buttonStyle(GhostButtonStyle(height: 44, fontSize: 14, bordered: false))
                .opacity(step == 0 ? 0 : 1)
                .disabled(step == 0)
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.count, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color(nsColor: NSColor(hex: 0x2456c9))
                              : i < step ? Color(nsColor: NSColor(hex: 0x8ea4dc)) : Theme.line)
                        .frame(width: i == step ? 20 : 6, height: 6)
                }
            }
            Spacer()
            Button(primaryTitle, action: primary)
                .buttonStyle(PrimaryButtonStyle(height: 44, fontSize: 14))
                .disabled(!canContinue)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .frame(height: 76)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var primaryTitle: String {
        switch step {
        case 0: "Get started"
        case 6: practiced.isEmpty ? "Skip for now" : "Continue"
        case Self.count - 1: "Start using HoTTy"
        default: "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case 1: state.microphone == .authorized && state.speech == .authorized
        case 2: state.accessibilityGranted
        default: true
        }
    }

    private func primary() {
        if step == Self.count - 1 { windows.finishOnboarding() } else { go(step + 1) }
    }

    private func go(_ s: Int) {
        coordinator.practiceCancel()
        withAnimation(.easeOut(duration: 0.18)) { step = max(0, min(Self.count - 1, s)) }
    }
}

// MARK: - Shared pieces

private struct StepHeader: View {
    let title: String
    let lede: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 28, weight: .bold))
            Text(lede)
                .font(.system(size: 15))
                .foregroundStyle(Theme.mute)
                .lineSpacing(3)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A permission line: letter tile, name and reason, then its state.
private struct PermRow: View {
    let letter: String
    let name: String
    let why: String
    let status: Status
    var open: () -> Void = {}

    enum Status { case waiting, allowed, denied }

    var body: some View {
        HStack(spacing: 14) {
            ArrowTile(text: letter, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 14, weight: .semibold))
                Text(why).font(.system(size: 12)).foregroundStyle(Theme.mute)
            }
            Spacer()
            switch status {
            case .waiting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for you…").font(.system(size: 12)).foregroundStyle(Theme.mute)
                }
            case .allowed:
                Chip(text: "Allowed", systemImage: "checkmark", fg: Theme.ok, bg: Theme.okBg)
            case .denied:
                Chip(text: "Off", fg: Theme.bad, bg: Theme.badBg)
                Button("Open Settings", action: open).buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 60)
    }
}

// MARK: - 1 Welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AppIconImage(size: 76)
            StepHeader(title: "Talk anywhere you can type",
                       lede: "Hold down on any text field, say what you want to write, and let go. HoTTy types it for you, in any app.")
            VStack(alignment: .leading, spacing: 14) {
                feature("hand.tap", "Hold, speak, let go", "No shortcut to remember. The hold is the button.")
                feature("arrow.left.and.right", "Drag to decide", "Drag right to send, left to cancel, up to go hands-free.")
                feature("lock", "Private by design", "Speech is turned into text on this Mac. Nothing is uploaded.")
            }
        }
    }

    private func feature(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accText)
                .frame(width: 36, height: 36)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(desc).font(.system(size: 13)).foregroundStyle(Theme.mute)
            }
        }
    }
}

// MARK: - 2 Microphone and speech

private struct VoiceStep: View {
    let coordinator: Coordinator
    private var state: AppState { coordinator.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StepHeader(title: "Let HoTTy hear you",
                       lede: "macOS asks twice: once for the microphone, once for speech recognition. Both stay on this Mac.")
            VStack(spacing: 0) {
                PermRow(letter: "M", name: "Microphone", why: "Listens only while you hold",
                        status: status(state.microphone == .authorized, state.microphone == .notDetermined),
                        open: SystemSettings.microphone)
                Rectangle().fill(Theme.line).frame(height: 1)
                PermRow(letter: "S", name: "Speech recognition", why: "Turns your voice into text, on device",
                        status: status(state.speech == .authorized, state.speech == .notDetermined),
                        open: SystemSettings.speech)
            }
            .card()
            if state.microphone == .notDetermined || state.speech == .notDetermined {
                Button("Ask again") { Task { await request() } }.buttonStyle(LinkButtonStyle())
            }
        }
        .task { await request() }
    }

    private func status(_ ok: Bool, _ undetermined: Bool) -> PermRow.Status {
        ok ? .allowed : undetermined ? .waiting : .denied
    }

    private func request() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        coordinator.refreshPermissions()
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
            }
        }
        coordinator.refreshPermissions()
    }
}

// MARK: - 3 Accessibility

private struct AccessStep: View {
    let coordinator: Coordinator
    private var granted: Bool { coordinator.state.accessibilityGranted }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Let HoTTy type for you",
                       lede: "Accessibility access lets HoTTy notice when you hold on a text field and type your words there. Switch HoTTy on in the list.")
            HStack(alignment: .top, spacing: 18) {
                // A picture of the switch to flip, so the Settings pane is familiar when it opens.
                VStack(spacing: 0) {
                    Text("Privacy & Security › Accessibility")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                    mockRow(icon: nil, "Terminal", on: true, dim: true)
                    mockRow(icon: AnyView(AppIconImage(size: 22)), "HoTTy", on: granted, dim: false)
                    mockRow(icon: nil, "Zoom", on: false, dim: true)
                }
                .frame(width: 290)
                .card(radius: 12)

                VStack(alignment: .leading, spacing: 12) {
                    if granted {
                        Chip(text: "Access granted", systemImage: "checkmark", fg: Theme.ok, bg: Theme.okBg)
                        Text("All set. HoTTy can now type into other apps.")
                            .font(.system(size: 13)).foregroundStyle(Theme.mute)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for access…").font(.system(size: 13, weight: .semibold))
                        }
                        Text("This page moves on by itself once HoTTy is switched on.")
                            .font(.system(size: 13)).foregroundStyle(Theme.mute)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open System Settings") { SystemSettings.accessibility() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                .padding(.top, 6)
            }
        }
        .onChange(of: granted) { _, now in
            if now { NSApp.activate() }   // come back from System Settings
        }
    }

    private func mockRow(icon: AnyView?, _ name: String, on: Bool, dim: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon { icon } else {
                RoundedRectangle(cornerRadius: 5).fill(Theme.line).frame(width: 22, height: 22)
            }
            Text(name).font(.system(size: 13, weight: dim ? .regular : .semibold))
            Spacer()
            PillSwitch(isOn: .constant(on)).allowsHitTesting(false).scaleEffect(0.8)
        }
        .opacity(dim ? 0.5 : 1)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(dim ? .clear : Theme.soft.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}

// MARK: - 4 Hold style

private struct HoldStep: View {
    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue
    @AppStorage(Pref.holdDuration) private var hold = 0.4

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "How do you want to start?",
                       lede: "Pick the hold that feels natural. You can change it any time from the menu bar.")
            HStack(spacing: 14) {
                option(.clickHold, icon: "cursorarrow.click", title: "Press & hold",
                       desc: "Click down on a text field and keep holding. Works with any mouse or trackpad.")
                option(.touchHold, icon: "hand.point.up.left", title: "Rest a finger",
                       desc: "Rest one finger on the trackpad over a text field, without clicking.")
            }
            HStack(spacing: 14) {
                Text("Start listening after").font(.system(size: 14, weight: .semibold))
                Slider(value: $hold, in: Pref.holdDurationRange, step: 0.05).frame(width: 220).tint(Theme.acc)
                Text(String(format: "%.2f s", hold)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
        }
    }

    private func option(_ mode: TriggerMode, icon: String, title: String, desc: String) -> some View {
        let on = trigger == mode.rawValue
        return Button { trigger = mode.rawValue } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundStyle(Theme.accText)
                    Spacer()
                    Circle().strokeBorder(on ? Theme.acc : Theme.line, lineWidth: on ? 6 : 2).frame(width: 20, height: 20)
                }
                Text(title).font(.system(size: 16, weight: .bold))
                Text(desc).font(.system(size: 13)).foregroundStyle(Theme.mute).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(on ? Theme.soft.opacity(0.5) : Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Theme.acc : Theme.line, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 5 Gestures

private struct GesturesStep: View {
    @State private var pick = "down"

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Drag to choose what happens",
                       lede: "While you hold, drag a finger's width in one direction. Then let go.")
            HStack(alignment: .center, spacing: 28) {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow { Color.clear.frame(width: 52, height: 52); tile("up"); Color.clear.frame(width: 52, height: 52) }
                    GridRow {
                        tile("left")
                        Circle().fill(Theme.acc).frame(width: 16, height: 16).frame(width: 52, height: 52)
                        tile("right")
                    }
                    GridRow { Color.clear.frame(width: 52, height: 52); tile("down"); Color.clear.frame(width: 52, height: 52) }
                }
                let g = GestureInfo.all.first { $0.id == pick }!
                VStack(alignment: .leading, spacing: 10) {
                    Text(g.title).font(.system(size: 17, weight: .bold))
                    Text(g.desc).font(.system(size: 14)).foregroundStyle(Theme.mute).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    OverlaySample(text: "See you at six", badge: g.badge, color: g.color, struck: g.id == "left")
                        .padding(.top, 4)
                }
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                .card()
            }
        }
    }

    private func tile(_ id: String) -> some View {
        let g = GestureInfo.all.first { $0.id == id }!
        let on = pick == id
        return Button { withAnimation(.easeOut(duration: 0.15)) { pick = id } } label: {
            Text(g.arrow)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(on ? .white : Theme.accText)
                .frame(width: 52, height: 52)
                .background(on ? Theme.acc : Theme.soft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { withAnimation(.easeOut(duration: 0.15)) { pick = id } } }
    }
}

// MARK: - 6 Language

private struct LanguageStep: View {
    let coordinator: Coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            StepHeader(title: "Which language do you speak?",
                       lede: "HoTTy uses Apple's on-device speech model. It downloads once, then works offline.")
            HStack(spacing: 12) {
                Text("Language").font(.system(size: 14, weight: .semibold))
                LanguagePicker(width: 280)
            }
            HStack(spacing: 14) {
                switch coordinator.state.model {
                case .ready:
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.ok)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(Theme.bad)
                default:
                    ProgressView().controlSize(.small).frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(modelLine(coordinator.state.model)).font(.system(size: 14, weight: .semibold))
                    if case .downloading(let f) = coordinator.state.model {
                        ProgressView(value: f).tint(Theme.acc).frame(width: 300)
                        Text("You can continue while it downloads.").font(.system(size: 12)).foregroundStyle(Theme.mute)
                    }
                }
                Spacer()
                if case .failed = coordinator.state.model {
                    Button("Retry") { coordinator.ensureModel() }.buttonStyle(GhostButtonStyle())
                }
            }
            .padding(18)
            .card()
        }
    }
}

// MARK: - 7 Try it

enum PracticeResult: Hashable { case insert, send, cancel, free }

private struct TryStep: View {
    let coordinator: Coordinator
    @Binding var done: Set<PracticeResult>

    private enum Mode: Equatable { case idle, arming, listening, handsFree, finishing }
    @State private var mode = Mode.idle
    @State private var text = ""
    @State private var level: Float = 0
    @State private var drag = CGSize.zero
    @State private var message: String?
    @State private var armTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "Give it a try",
                       lede: "Press and hold in the box below, say something, then let go. Try dragging before you let go, too.")
            box
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
                GridRow { check(.insert, "Let go to insert"); check(.send, "Drag right to send") }
                GridRow { check(.cancel, "Drag left to cancel"); check(.free, "Drag up for hands-free") }
            }
        }
        .onDisappear { armTask?.cancel(); coordinator.practiceCancel() }
    }

    private var action: PracticeResult {
        if drag.height <= -60 { return .free }
        if drag.width >= 60 { return .send }
        if drag.width <= -60 { return .cancel }
        return .insert
    }

    private var box: some View {
        let listening = mode == .listening || mode == .handsFree
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if listening {
                    LiveMeter(level: level)
                    Text(mode == .handsFree ? "Hands-free. Keep talking." : "Listening…")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accText)
                    if mode == .listening, let b = badge { GestureBadge(text: b.0, color: b.1) }
                } else {
                    Text(mode == .arming ? "Keep holding…" : "Press and hold here")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mute)
                }
                Spacer()
                if mode == .handsFree {
                    Button("Cancel") { Task { await end(.cancel) } }.buttonStyle(GhostButtonStyle(height: 28))
                    Button("Finish") { Task { await end(.insert) } }.buttonStyle(GhostButtonStyle(height: 28))
                    Button("Send") { Task { await end(.send) } }.buttonStyle(PrimaryButtonStyle(height: 28))
                }
            }
            Group {
                if text.isEmpty {
                    Text(message ?? "Your words appear here.").foregroundStyle(Theme.mute)
                } else {
                    Text(text)
                        .strikethrough(mode == .listening && action == .cancel, color: Theme.cancel)
                        .opacity(mode == .listening && action == .cancel ? 0.5 : 1)
                }
            }
            .font(.system(size: 15))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !text.isEmpty, let message, mode == .idle {
                Text(message).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ok)
            }
        }
        .padding(16)
        .frame(height: 150)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(listening ? Theme.acc : Theme.line, lineWidth: listening ? 2 : 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if mode == .idle { arm() }
                    drag = v.translation
                }
                .onEnded { _ in released() }
        )
    }

    private var badge: (String, Color)? {
        switch action {
        case .send: ("↵ Send", Theme.send)
        case .cancel: ("✕ Cancel", Theme.cancel)
        case .free: ("Lock", Theme.indigo)
        case .insert: nil
        }
    }

    private func check(_ r: PracticeResult, _ label: String) -> some View {
        HStack(spacing: 7) {
            CheckDot(done: done.contains(r))
            Text(label).font(.system(size: 13, weight: .medium))
                .foregroundStyle(done.contains(r) ? Theme.text : Theme.mute)
        }
    }

    private func arm() {
        mode = .arming
        message = nil
        armTask = Task {
            try? await Task.sleep(for: .seconds(Pref.hold))
            guard !Task.isCancelled, mode == .arming else { return }
            text = ""
            let cb = Coordinator.PracticeCallbacks(text: { s in text = s }, level: { l in level = l })
            if let err = coordinator.practiceStart(cb) {
                mode = .idle
                message = err
            } else {
                mode = .listening
            }
        }
    }

    private func released() {
        switch mode {
        case .arming:
            armTask?.cancel()
            mode = .idle
            message = "Hold a little longer, until the box turns blue."
        case .listening:
            let a = action
            if a == .free {
                mode = .handsFree
                done.insert(.free)
                coordinator.store.markDone(.free)
            } else {
                Task { await end(a) }
            }
        default: break
        }
        drag = .zero
    }

    private func end(_ a: PracticeResult) async {
        mode = .finishing
        if a == .cancel {
            coordinator.practiceCancel()
            text = ""
            message = "Cancelled. Nothing was typed."
        } else {
            text = await coordinator.practiceFinish(send: a == .send)
            if text.isEmpty {
                message = "HoTTy didn't catch anything. Try speaking a bit louder."
            } else {
                message = a == .send ? "Sent. In a chat app, this also presses Return." : "Inserted where you held."
            }
            if a == .send { coordinator.store.markDone(.send) }
        }
        if a != .insert || !text.isEmpty { done.insert(a) }
        level = 0
        mode = .idle
    }
}

/// Four bars that follow the microphone level.
private struct LiveMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                let scale: [CGFloat] = [0.6, 1, 0.8, 0.5]
                Capsule().fill(Theme.send)
                    .frame(width: 3, height: 4 + 12 * CGFloat(min(1, max(0, level))) * scale[i])
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

// MARK: - 8 Done

private struct DoneStep: View {
    let coordinator: Coordinator
    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepHeader(title: "You're all set",
                       lede: "HoTTy lives in the menu bar. \(holdHint(trigger))")
            HStack(spacing: 14) {
                // The menu bar, with HoTty's icon picked out.
                HStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "wifi")
                    Image(systemName: "battery.75percent")
                    Image(nsImage: HoTtyMark.image(.idle, height: 14))
                        .renderingMode(.template)
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 22)
                        .background(Theme.acc, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(Date().formatted(date: .omitted, time: .shortened))
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(width: 300, height: 34)
                .card(radius: 9)
                Text("← Click here for the menu, settings and history.")
                    .font(.system(size: 13)).foregroundStyle(Theme.mute)
            }
            HStack(spacing: 12) {
                PillSwitch(isOn: $login)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open HoTTy when I log in").font(.system(size: 14, weight: .semibold))
                    Text(loginError ?? "So it's ready after every restart").font(.system(size: 12)).foregroundStyle(Theme.mute)
                }
            }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    tip("book.closed", "Teach it words", "Add names and jargon in Vocabulary.")
                    tip("clock", "Find anything", "Every dictation is kept in History, on this Mac.")
                }
                GridRow {
                    tip("pause.circle", "Need a break?", "Pause for an hour from the menu bar.")
                    tip("doc.on.doc", "Copy last", "Copy your last dictation from the menu bar.")
                }
            }
        }
        .onChange(of: login) { _, on in
            loginError = setLoginItem(on)
            login = SMAppService.mainApp.status == .enabled
            if login { coordinator.store.markDone(.login) }
        }
    }

    private func tip(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accText).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(desc).font(.system(size: 12)).foregroundStyle(Theme.mute)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: 12)
    }
}
