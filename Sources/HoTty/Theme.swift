import AppKit
import SwiftUI

/// Design tokens from the HoTty design board, each with a light and a dark value.
enum Theme {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    static let bg = dyn(0xfbfaf8, 0x1c1d20)
    static let side = dyn(0xf0eee9, 0x242529)
    static let card = dyn(0xffffff, 0x2a2b30)
    static let line = dyn(0xe4e1db, 0x393a40)
    static let text = dyn(0x1d1d1f, 0xf2f2f3)
    static let mute = dyn(0x5f5e63, 0xa7a7ae)
    static let soft = dyn(0xe9eefb, 0x2e3957)
    static let acc = dyn(0x2456c9, 0x3f6fe0)
    static let accText = dyn(0x2456c9, 0x9ab8ff)
    static let hover = dyn(0xe7e4de, 0x303137)
    static let sel = dyn(0xdfdcd5, 0x393a42)
    static let ok = dyn(0x1f7a3d, 0x6fd28f)
    static let okBg = dyn(0xe3f1e7, 0x1f3326)
    static let warn = dyn(0x8a4b08, 0xf2c078)
    static let warnBg = dyn(0xf6ecdc, 0x3d3222)
    static let bad = dyn(0xb3261e, 0xff9a92)
    static let badBg = dyn(0xfbe6e4, 0x43221f)
    static let lock = dyn(0x4b3fc4, 0xaaa2ff)

    /// Fixed colors for the release-gesture badges, the same in the overlay and the guides.
    static let send = Color(nsColor: NSColor(hex: 0x2456c9))
    static let cancel = Color(nsColor: NSColor(hex: 0xc9342b))
    static let indigo = Color(nsColor: NSColor(hex: 0x4b3fc4))
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

// MARK: - Building blocks

extension View {
    /// White (or dark grey) rounded panel with a hairline border.
    func card(radius: CGFloat = 14) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line))
    }
}

/// Filled blue button, 36 pt tall (44 in onboarding).
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    var fontSize: CGFloat = 13
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, height > 40 ? 22 : 14)
            .frame(minHeight: height)
            .background(Theme.acc.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: height > 40 ? 10 : 9, style: .continuous))
            .contentShape(Rectangle())
    }
}

/// Outlined button on the page background.
struct GhostButtonStyle: ButtonStyle {
    var height: CGFloat = 36
    var fontSize: CGFloat = 13
    var bordered = true
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, height > 40 ? 22 : 14)
            .frame(minHeight: height)
            .background(configuration.isPressed || hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                if bordered { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Blue text button ("See all").
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.accText.opacity(configuration.isPressed ? 0.7 : 1))
            .padding(.horizontal, 4).padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}

/// Small rounded label, blue by default.
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var fg: Color = Theme.accText
    var bg: Color = Theme.soft
    var dot = false

    var body: some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(fg).frame(width: 8, height: 8) }
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)) }
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(fg)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Pill-shaped segmented control from the design ("Today / This week / All time").
struct Segmented<V: Hashable>: View {
    @Binding var selection: V
    let options: [(V, String)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                let on = value == selection
                Button { withAnimation(.easeOut(duration: 0.15)) { selection = value } } label: {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Theme.text : Theme.mute)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                        .background {
                            if on {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.card)
                                    .shadow(color: .black.opacity(0.14), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
    }
}

/// 40×24 switch in the design's style.
struct PillSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { isOn.toggle() } } label: {
            Capsule()
                .fill(isOn ? Theme.acc : Theme.line)
                .frame(width: 40, height: 24)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                        .padding(3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Round tinted tile holding an arrow or a letter.
struct ArrowTile: View {
    let text: String
    var size: CGFloat = 40

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.47, weight: .bold))
            .foregroundStyle(Theme.accText)
            .frame(width: size, height: size)
            .background(Theme.soft, in: Circle())
    }
}

/// Filled green circle with a check, or an empty ring.
struct CheckDot: View {
    let done: Bool

    var body: some View {
        ZStack {
            if done {
                Circle().fill(Theme.ok)
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.card)
            } else {
                Circle().strokeBorder(Theme.line, lineWidth: 2)
            }
        }
        .frame(width: 18, height: 18)
    }
}

/// The app icon, used for the logo tile in the sidebar and onboarding.
struct AppIconImage: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

/// The icon of the app a dictation went into, or its initial on a tile.
struct AppBadge: View {
    let name: String
    let bundleID: String?

    var body: some View {
        if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 30, height: 30)
        } else {
            Text(String(name.prefix(1)))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accText)
                .frame(width: 30, height: 30)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Four bars like the overlay's level meter, static.
struct MeterGlyph: View {
    var heights: [CGFloat] = [6, 12, 9, 5]
    var color: Color = Theme.send

    var body: some View {
        HStack(spacing: 2) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: 3, height: heights[i])
            }
        }
        .frame(height: 14)
    }
}

/// The overlay's release badge ("↵ Send").
struct GestureBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color, in: Capsule())
            .fixedSize()
    }
}
