import AppKit
import AVFoundation
import ServiceManagement
import Speech
import SwiftUI

@main
struct HoTtyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: appDelegate.coordinator, windows: appDelegate.windows)
        } label: {
            MenuIcon(coordinator: appDelegate.coordinator)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator: Coordinator = {
        Pref.registerDefaults()
        return Coordinator()
    }()
    private var lastTrigger = Pref.trigger
    private var lastLocale = Pref.locale.identifier
    private var permissionTimer: Timer?
    lazy var windows = Windows(coordinator: coordinator)

    func applicationDidFinishLaunching(_ note: Notification) {
        if !UserDefaults.standard.bool(forKey: Pref.onboarded) {
            // Onboarding asks for each permission with an explanation first.
            windows.showOnboarding()
        } else {
            if !AX.isTrusted { AX.promptForTrust() }
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                coordinator.refreshPermissions()
            }
            SFSpeechRecognizer.requestAuthorization { _ in
                DispatchQueue.main.async { self.coordinator.refreshPermissions() }
            }
        }
        // Opened from the Dock, Finder or Launchpad: show the window. Started at login: stay quiet
        // in the menu bar and Dock.
        if UserDefaults.standard.bool(forKey: Pref.onboarded) && !Self.launchedAtLogin {
            windows.showMain()
        }

        coordinator.applyTrigger()
        coordinator.ensureModel()
        if ProcessInfo.processInfo.environment["HOTTY_DEBUG_NAV"] != nil {
            // Screenshots: `notifyutil`-free page switching, e.g. object "settings/general".
            DistributedNotificationCenter.default().addObserver(forName: .init("llc.fungee.hotty.debug.page"), object: nil, queue: .main) { [weak self] n in
                let parts = (n.object as? String ?? "").split(separator: "/").map(String.init)
                MainActor.assumeIsolated {
                    let tab: SettingsTab? = switch parts.dropFirst().first {
                    case "general": .general
                    case "permissions": .permissions
                    case "dictation": .dictation
                    default: nil
                    }
                    self?.windows.showMain(parts.first.flatMap(Page.init(rawValue:)), tab: tab)
                }
            }
        }
        if ProcessInfo.processInfo.environment["HOTTY_OVERLAY_DEMO"] != nil { coordinator.demoOverlay() }
        if ProcessInfo.processInfo.environment["HOTTY_AUDIO_TEST"] != nil { coordinator.audioSelfTest() }
        if ProcessInfo.processInfo.environment["HOTTY_LOCK_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.coordinator.lockSelfTest() }
        }
        if ProcessInfo.processInfo.environment["HOTTY_GESTURE_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.coordinator.gestureSelfTest() }
        }
        if ProcessInfo.processInfo.environment["HOTTY_DEBUG_AX"] != nil {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                NSLog("HoTty AX: %@", AX.describe(at: ScreenGeometry.mouseCG))
            }
        }

        // Accessibility is granted in System Settings while we run; pick it up without a restart.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let was = self.coordinator.state.accessibilityGranted
                self.coordinator.refreshPermissions()
                if !was && self.coordinator.state.accessibilityGranted { self.coordinator.applyTrigger() }
            }
        }

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }

        // Chromium browsers (Edge, Chrome, Brave…) and Electron apps expose web content
        // to Accessibility only when asked: ask every app now and each one as it activates.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            AX.enableManualAccessibility(pid: app.processIdentifier)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                AX.enableManualAccessibility(pid: app.processIdentifier)
            }
        }
    }

    private static var launchedAtLogin: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.showMain()
        return false
    }

    private func preferencesChanged() {
        if Pref.trigger != lastTrigger {
            lastTrigger = Pref.trigger
            coordinator.applyTrigger()
        }
        if Pref.locale.identifier != lastLocale {
            lastLocale = Pref.locale.identifier
            coordinator.ensureModel()
        }
    }
}

// MARK: - Menu

private struct MenuIcon: View {
    let coordinator: Coordinator

    var body: some View {
        let s = coordinator.state
        Image(nsImage: HoTtyMark.image(s.listening ? .listening
                                       : coordinator.store.isPaused ? .paused : .idle))
    }
}

private struct MenuContent: View {
    let coordinator: Coordinator
    let windows: Windows
    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue
    @AppStorage(Pref.liveMode) private var live = LiveMode.overlay.rawValue

    private var state: AppState { coordinator.state }
    private var store: Store { coordinator.store }

    var body: some View {
        Text(title)
        Text(subtitle)
        Divider()
        Button("Open HoTty") { windows.showMain() }
            .keyboardShortcut("o")
        if store.isPaused {
            Button("Resume dictation") { coordinator.resume() }
        } else {
            Button("Pause for 1 hour") { coordinator.pause() }
        }
        Divider()
        Picker("Start dictation by", selection: $trigger) {
            ForEach(TriggerMode.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Picker("While speaking", selection: $live) {
            ForEach(LiveMode.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Divider()
        Button("Copy last dictation") { coordinator.copyLast() }
            .keyboardShortcut("c", modifiers: [.option, .command])
            .disabled(store.last == nil)
        Button("Gesture guide") { windows.showMain(.guide) }
        Button("Settings…") { windows.showMain(.settings) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit HoTty") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var title: String {
        if state.listening { return "Listening…" }
        if !state.accessibilityGranted { return "Needs Accessibility access" }
        if state.microphone != .authorized { return "Needs Microphone access" }
        if store.isPaused, let until = store.pausedUntil {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        if state.triggerError != nil { return "Hold detection is off" }
        if case .downloading(let f) = state.model { return "Downloading speech model · \(Int(f * 100))%" }
        return "Ready"
    }

    private var subtitle: String {
        if !state.accessibilityGranted || state.microphone != .authorized { return "Open HoTty to fix it" }
        if store.isPaused { return "Holding won't start dictation" }
        if let e = state.triggerError { return e }
        return trigger == TriggerMode.touchHold.rawValue
            ? "Rest a finger in a text field to speak" : "Press and hold in a text field to speak"
    }
}
