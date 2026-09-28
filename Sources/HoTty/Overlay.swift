import AppKit
import SwiftUI

@MainActor @Observable
final class OverlayModel {
    enum Phase { case listening, finishing }
    var phase = Phase.listening
    var text = ""                 // display text, already trimmed to fit
    var textWidth: CGFloat = 0    // grows during a session, never shrinks, so the panel doesn't jitter
    var level: Float = 0
}

/// A small non-activating panel near the pointer: a live level meter, plus the words
/// still being recognized when the preview overlay mode is on.
@MainActor
final class OverlayController {
    private let model = OverlayModel()
    private var panel: NSPanel?
    private var anchor = CGPoint.zero

    fileprivate static let font = NSFont.systemFont(ofSize: 14)
    fileprivate static let maxTextWidth: CGFloat = 340
    private static let maxLines = 2
    /// The panel never resizes: resizing a window whose content is SwiftUI triggers
    /// AppKit update-constraints loops that abort the app. The visible box is drawn
    /// inside, pinned top-left, and the rest of the panel is transparent and click-through.
    fileprivate static let shadowInset: CGFloat = 14
    private static let panelSize = CGSize(width: maxTextWidth + 80 + shadowInset * 2, height: 72 + shadowInset * 2)

    func show(at cgPoint: CGPoint) {
        anchor = cgPoint
        model.phase = .listening
        model.text = ""
        model.textWidth = 0
        model.level = 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()
    }

    func setText(_ s: String) {
        let (display, width) = Self.fit(s.trimmingCharacters(in: .whitespacesAndNewlines))
        model.text = display
        model.textWidth = max(model.textWidth, width)
        reposition()
    }

    func setLevel(_ l: Float) { model.level = l }
    func finishing() { model.phase = .finishing }
    func hide() { panel?.orderOut(nil) }

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
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel],
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
        let host = NSHostingView(rootView: OverlayView(model: model))
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

struct OverlayView: View {
    let model: OverlayModel
    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            LevelMeter(level: model.phase == .listening ? model.level : 0, active: model.phase == .listening)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Group {
                if model.text.isEmpty {
                    Text(model.phase == .listening ? "Listening…" : "Finishing…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.text)
                        .foregroundStyle(.primary.opacity(0.88))
                        .lineSpacing(2)
                        .frame(width: model.textWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(Font(OverlayController.font))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thickMaterial, in: Self.shape)
        .overlay(Self.shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(OverlayController.shadowInset)   // room for the shadow inside the transparent panel
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                    .fill(active ? Color.red : Color.secondary)
                    .frame(width: 2.5, height: 4 + 10 * CGFloat(level) * Self.weights[i])
            }
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
