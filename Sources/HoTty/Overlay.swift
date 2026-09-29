import AppKit
import SwiftUI

/// What releasing the hold will do, chosen by dragging.
enum ReleaseAction {
    case finish   // type what was said
    case send     // type it, then press Return
    case cancel   // discard and restore the field
    case lock     // keep listening hands-free; end from the overlay buttons
}

@MainActor @Observable
final class OverlayModel {
    enum Phase { case listening, finishing }
    var phase = Phase.listening
    var text = ""                 // display text, already trimmed to fit
    var textWidth: CGFloat = 0    // grows during a session, never shrinks, so the panel doesn't jitter
    var level: Float = 0
    var action = ReleaseAction.finish
    var hint = false              // the user has started dragging: show the gesture directions
    var locked = false            // hands-free: show the timer and buttons
    var lockedAt = Date()
    var waitingWords = 0          // hands-free: words held while the field lacks focus
    var flash: String?            // brief status that replaces the text, e.g. "Copied to clipboard"
    var notice = false            // a message shown instead of a session: no meter, no hints
    var progress: Double?         // with a notice: a progress bar, e.g. the model download
    var boxFrame = CGRect.zero    // the visible box, in hosting-view coordinates (top-left origin)
    var onButton: ((ReleaseAction) -> Void)?
}

/// A small non-activating panel near the pointer: a live level meter, plus the words
/// still being recognized when the preview overlay mode is on. In hands-free mode it
/// also carries the Cancel / Finish / Send buttons, the only way to end that mode.
@MainActor
final class OverlayController {
    private let model = OverlayModel()
    private var panel: NSPanel?
    private var anchor = CGPoint.zero
    private var hoverPoll: Timer?

    var onButton: ((ReleaseAction) -> Void)? {
        get { model.onButton }
        set { model.onButton = newValue }
    }

    fileprivate static let font = NSFont.systemFont(ofSize: 14)
    fileprivate static let maxTextWidth: CGFloat = 340
    private static let maxLines = 2
    /// The panel never resizes: resizing a window whose content is SwiftUI triggers
    /// AppKit update-constraints loops that abort the app. The visible box is drawn
    /// inside, pinned top-left, and the rest of the panel is transparent and click-through.
    fileprivate static let shadowInset: CGFloat = 14
    private static let panelSize = CGSize(width: maxTextWidth + 180 + shadowInset * 2, height: 112 + shadowInset * 2)

    func show(at cgPoint: CGPoint) {
        anchor = cgPoint
        model.phase = .listening
        model.text = ""
        model.textWidth = 0
        model.level = 0
        model.action = .finish
        model.hint = false
        model.locked = false
        model.waitingWords = 0
        model.flash = nil
        model.notice = false
        model.progress = nil
        noticeHide?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = true
        reposition()
        panel.orderFrontRegardless()
    }

    func setText(_ s: String) {
        let (display, width) = Self.fit(s.trimmingCharacters(in: .whitespacesAndNewlines))
        model.text = display
        model.textWidth = max(model.textWidth, width)
    }

    func setLevel(_ l: Float) { model.level = l }
    func setAction(_ a: ReleaseAction) { model.action = a }
    func setHint(_ on: Bool) { if model.hint != on { model.hint = on } }
    func setWaiting(_ n: Int) { if model.waitingWords != n { model.waitingWords = n } }
    func flash(_ message: String) { model.flash = message }

    /// Shows a short message at `cgPoint` when no session is running, then hides it.
    func notice(_ text: String, at cgPoint: CGPoint, progress: Double? = nil) {
        show(at: cgPoint)
        model.notice = true
        model.flash = text
        model.progress = progress
        model.phase = .finishing
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        noticeHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }
    private var noticeHide: DispatchWorkItem?

    func finishing() {
        model.phase = .finishing
        stopHoverPoll()
    }

    func hide() {
        stopHoverPoll()
        panel?.orderOut(nil)
    }

    /// Hands-free: show the buttons and make them clickable.
    func setLocked(_ on: Bool) {
        model.locked = on
        model.action = .finish
        model.hint = false
        model.lockedAt = Date()
        on ? startHoverPoll() : stopHoverPoll()
    }

    /// The panel is larger than the visible box, and a window takes clicks across its
    /// whole frame. So it accepts mouse events only while the pointer is over the box,
    /// and lets everything else fall through to the apps below.
    private func startHoverPoll() {
        stopHoverPoll()
        hoverPoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                let box = self.model.boxFrame
                let screenBox = CGRect(x: panel.frame.minX + box.minX, y: panel.frame.maxY - box.maxY,
                                       width: box.width, height: box.height)
                let inside = screenBox.contains(NSEvent.mouseLocation)
                if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
            }
        }
    }

    private func stopHoverPoll() {
        hoverPoll?.invalidate()
        hoverPoll = nil
        panel?.ignoresMouseEvents = true
    }

    /// Wraps at `maxTextWidth` and keeps the newest words: while the text needs more
    /// than `maxLines` lines, drop words from the front and lead with an ellipsis.
    private static func fit(_ s: String) -> (String, CGFloat) {
        guard !s.isEmpty else { return ("", 0) }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        func size(_ t: String, width: CGFloat) -> CGSize {
            (t as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin], attributes: attrs).size
        }
        let lineHeight = size("Ag", width: .greatestFiniteMagnitude).height
        var words = s.split(separator: " ")
        var display = s
        while words.count > 1, size(display, width: maxTextWidth).height > lineHeight * CGFloat(maxLines) + 1 {
            words.removeFirst()
            display = "…" + words.joined(separator: " ")
        }
        // The wrapped bounding width is the longest line, so ragged text doesn't leave a gap.
        return (display, ceil(size(display, width: maxTextWidth).width) + 2)
    }

    private func makePanel() -> NSPanel {
        let p = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false   // the view draws a softer shadow than the window server's
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // The panel's size is set only by reposition(); letting the hosting view also
        // drive window size constraints causes an update-constraints loop that AppKit
        // aborts on.
        let host = FirstMouseHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        p.contentView = host
        return p
    }

    /// Puts the box's top-left just below and right of the pointer, kept on the
    /// pointer's screen. Only the origin changes; the box grows downward inside the panel.
    private func reposition() {
        guard let panel else { return }
        let size = Self.panelSize
        let pt = ScreenGeometry.cocoa(fromCG: anchor)
        let screen = NSScreen.screens.first { $0.frame.contains(pt) } ?? NSScreen.main
        var origin = NSPoint(x: pt.x + 6, y: pt.y - 14 - size.height)
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX - Self.shadowInset), vf.maxX - size.width + Self.shadowInset)
            origin.y = max(origin.y, vf.minY - Self.shadowInset)
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

/// Never becomes key, so clicking its buttons can't take keyboard focus from the field
/// being dictated into.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons respond to the first click even though HoTty is never the active app.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct OverlayView: View {
    let model: OverlayModel
    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    private var tint: Color? {
        switch model.action {
        case .finish: nil
        case .send: .accentColor
        case .cancel: .red
        case .lock: .indigo
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if model.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.indigo)
                }
                if !model.notice {
                    LevelMeter(level: model.phase == .listening ? model.level : 0, active: model.phase == .listening)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
                mainText.font(Font(OverlayController.font))
                if model.action != .finish {
                    ActionBadge(action: model.action)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
                }
            }
            if let p = model.progress {
                ProgressView(value: p).progressViewStyle(.linear).tint(Theme.send).frame(width: 260)
            }
            if model.locked && model.phase == .listening {
                lockedControls
            } else if model.hint && model.phase == .listening {
                Text("←  cancel     ↑  lock     send  →")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: Self.shape)
        .overlay(Self.shape.strokeBorder(tint?.opacity(0.7) ?? .primary.opacity(0.08), lineWidth: tint == nil ? 0.5 : 1.5))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.boxFrame = $0 }
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(OverlayController.shadowInset)   // room for the shadow inside the transparent panel
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var mainText: some View {
        if let flash = model.flash {
            Text(flash).foregroundStyle(.secondary)
        } else if model.text.isEmpty {
            Text(model.phase == .listening ? "Listening…" : "Finishing…")
                .foregroundStyle(.secondary)
        } else {
            Text(model.text)
                .foregroundStyle(.primary.opacity(model.action == .cancel ? 0.35 : 0.88))
                .strikethrough(model.action == .cancel, color: .red.opacity(0.6))
                .lineSpacing(2)
                .frame(width: model.textWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Hands-free: elapsed time, paused status, and the only way out.
    private var lockedControls: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: model.lockedAt, by: 1)) { ctx in
                let s = max(0, Int(ctx.date.timeIntervalSince(model.lockedAt)))
                Text(String(format: "%d:%02d", s / 60, s % 60))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.waitingWords > 0 {
                Text("Paused · \(model.waitingWords) word\(model.waitingWords == 1 ? "" : "s") waiting")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize()
            }
            Spacer(minLength: 16)
            Button { model.onButton?(.cancel) } label: { Label("Cancel", systemImage: "xmark") }
            Button { model.onButton?(.finish) } label: { Label("Finish", systemImage: "checkmark") }
            Button { model.onButton?(.send) } label: { Label("Send", systemImage: "return") }
                .buttonStyle(SendButtonStyle())
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .fixedSize()
    }
}

/// Always drawn in the accent color: system prominent buttons turn grey in windows that
/// aren't key, and this panel never becomes key.
private struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.7 : 1),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// "↵ Send" / "✕ Cancel" / "🔒 Lock": what letting go will do.
private struct ActionBadge: View {
    let action: ReleaseAction

    var body: some View {
        let (label, icon, color): (String, String, Color) = switch action {
        case .send: ("Send", "return", .accentColor)
        case .lock: ("Lock", "lock.fill", .indigo)
        default: ("Cancel", "xmark", .red)
        }
        Label(label, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .fixedSize()
    }
}

/// Four bars that bounce with the mic level; grey while finishing.
private struct LevelMeter: View {
    let level: Float
    let active: Bool
    private static let weights: [CGFloat] = [0.55, 1.0, 0.75, 0.4]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Self.weights.indices, id: \.self) { i in
                Capsule()
                    .fill(active ? Theme.send : Color.secondary)
                    .frame(width: 2.5, height: 4 + 10 * CGFloat(level) * Self.weights[i])
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
