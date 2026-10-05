import AppKit
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, history, vocab, guide, news, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .history: "History"
        case .vocab: "Vocabulary"
        case .guide: "Gestures"
        case .news: "What's new"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .history: "clock"
        case .vocab: "book.closed"
        case .guide: "arrow.up.and.down.and.arrow.left.and.right"
        case .news: "sparkles"
        case .settings: "slider.horizontal.3"
        }
    }
}

enum SettingsTab: Hashable { case dictation, general, permissions }

/// Which page and settings tab the main window shows.
@MainActor @Observable
final class Nav {
    var page = Page.home
    var tab = SettingsTab.dictation
}

/// Opens and reuses HoTty's two windows: the main window and onboarding. HoTty also lives
/// in the menu bar, so opening a window from there activates the app first.
@MainActor
final class Windows: NSObject, NSWindowDelegate {
    let coordinator: Coordinator
    let nav = Nav()
    private var main: NSWindow?
    private var onboarding: NSWindow?

    init(coordinator: Coordinator) {
        self.coordinator = coordinator
    }

    func showMain(_ page: Page? = nil, tab: SettingsTab? = nil) {
        if let page { nav.page = page }
        if let tab { nav.tab = tab }
        coordinator.refreshPermissions()
        let w = main ?? makeMain()
        main = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        let w = onboarding ?? makeOnboarding()
        onboarding = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// Onboarding's last button: close it and land in the app.
    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Pref.onboarded)
        onboarding?.close()
        showMain(.home)
    }

    private func makeMain() -> NSWindow {
        let w = HeaderDragWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "HoTty"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 900, height: 620)
        let host = NSHostingController(rootView: MainView(coordinator: coordinator, windows: self, nav: nav))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 1040, height: 680))
        w.center()
        w.setFrameAutosaveName("HoTtyMain")
        w.delegate = self
        return w
    }

    private func makeOnboarding() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Welcome to HoTty"
        w.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: OnboardingView(coordinator: coordinator, windows: self))
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(NSSize(width: 720, height: 540))
        w.center()
        w.delegate = self
        return w
    }

    func windowWillClose(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        // Onboarding rebuilds from step 1 next time; closing it midway leaves it unfinished.
        if w === onboarding {
            onboarding = nil
            coordinator.practiceCancel()
        }
    }
}

/// The main window draws its own header where a title bar would be, and SwiftUI content
/// there swallows most clicks, so only a thin strip at the very top moved the window.
/// This makes the whole header (the top bar, and the sidebar at the same height) move it
/// from anywhere, and double-click it like a title bar. The header has no clickable
/// SwiftUI controls; the traffic-light buttons are AppKit controls and keep working.
final class HeaderDragWindow: NSWindow {
    static let headerHeight: CGFloat = 54
    static let sidebarWidth: CGFloat = 224
    static let sidebarHeaderHeight: CGFloat = 88   // down to the first page row
    private let debug = ProcessInfo.processInfo.environment["HOTTY_DEBUG_DRAG"] != nil

    override func sendEvent(_ event: NSEvent) {
        if debug, event.type == .leftMouseDown {
            let p = event.locationInWindow
            let hit = contentView?.superview?.hitTest(p)
            NSLog("drag: click x=%.0f fromTop=%.0f clicks=%d hit=%@ header=%@", p.x,
                  frame.height - p.y, event.clickCount, hit.map { "\(type(of: $0))" } ?? "nil",
                  inHeader(p) ? "yes" : "no")
        }
        if event.type == .leftMouseDown, inHeader(event.locationInWindow) {
            if event.clickCount == 2 {
                titleBarDoubleClick()
            } else {
                performDrag(with: event)
            }
            return
        }
        super.sendEvent(event)
    }

    private func inHeader(_ p: NSPoint) -> Bool {
        let height = p.x < Self.sidebarWidth ? Self.sidebarHeaderHeight : Self.headerHeight
        guard let content = contentView, p.y >= content.frame.height - height else { return false }
        // The frame view is the root, so hitTest takes window coordinates here.
        return !(content.superview?.hitTest(p) is NSControl)
    }

    /// Follows System Settings › Desktop & Dock › "Double-click a window's title bar to".
    /// The choices are stored as "Fill", "Maximize" (Zoom), "Minimize" and "None". When
    /// it's unset, macOS fills unless the older minimize-on-double-click switch is on.
    private func titleBarDoubleClick() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Maximize": performZoom(nil)
        case "Minimize": performMiniaturize(nil)
        case "None": break
        case "Fill": toggleFill()
        case nil: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? performMiniaturize(nil) : toggleFill()
        default: break   // an action this macOS doesn't know yet: do nothing, like the system
        }
    }

    /// The frame before Fill, so a second double-click puts the window back.
    private var frameBeforeFill: NSRect?

    /// Fill: the space between the menu bar and the Dock. Double-clicking a filled
    /// window restores its previous size and position.
    private func toggleFill() {
        guard let area = screen?.visibleFrame else { return }
        if let previous = frameBeforeFill, frame.equalTo(area) {
            frameBeforeFill = nil
            setFrame(previous, display: true, animate: true)
        } else {
            frameBeforeFill = frame
            setFrame(area, display: true, animate: true)
        }
    }
}

/// Opens the right pane of System Settings › Privacy & Security.
enum SystemSettings {
    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
    static func accessibility() {
        AX.promptForTrust()   // adds HoTty to the list, so the user only has to switch it on
        open("Privacy_Accessibility")
    }
    static func microphone() { open("Privacy_Microphone") }
    static func speech() { open("Privacy_SpeechRecognition") }
}
