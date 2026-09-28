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
            MenuContent(state: appDelegate.coordinator.state)
        } label: {
            Image(systemName: appDelegate.coordinator.state.listening ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(coordinator: appDelegate.coordinator)
        }
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

    func applicationDidFinishLaunching(_ note: Notification) {
        if !AX.isTrusted { AX.promptForTrust() }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            coordinator.refreshPermissions()
        }
        SFSpeechRecognizer.requestAuthorization { _ in }

        coordinator.applyTrigger()
        coordinator.ensureModel()
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

private struct MenuContent: View {
    let state: AppState
    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue
    @AppStorage(Pref.liveMode) private var live = LiveMode.overlay.rawValue

    var body: some View {
        Text(statusLine)
        Divider()
        Picker("Trigger", selection: $trigger) {
            ForEach(TriggerMode.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Picker("Live Text", selection: $live) {
            ForEach(LiveMode.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit HoTty") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        if state.listening { return "Listening…" }
        if !state.accessibilityGranted { return "Needs Accessibility permission" }
        if state.microphone != .authorized { return "Needs Microphone permission" }
        if let e = state.triggerError { return e }
        return "HoTty is ready"
    }
}

// MARK: - Settings

private struct SettingsView: View {
    let coordinator: Coordinator
    private var state: AppState { coordinator.state }

    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue
    @AppStorage(Pref.liveMode) private var live = LiveMode.overlay.rawValue
    @AppStorage(Pref.caretPlacement) private var caret = CaretPlacement.atPointer.rawValue
    @AppStorage(Pref.holdDuration) private var hold = 0.4
    @AppStorage(Pref.localeID) private var localeID = ""
    @AppStorage(Pref.playSounds) private var sounds = true
    @AppStorage(Pref.ignoreThumbZone) private var thumbZone = true
    @State private var locales: [Locale] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Trigger") {
                Picker("Hold gesture", selection: $trigger) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Hold for") {
                    HStack {
                        Slider(value: $hold, in: Pref.holdDurationRange, step: 0.05)
                        Text(String(format: "%.2f s", hold))
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                if trigger == TriggerMode.touchHold.rawValue {
                    Toggle("Ignore touches along the bottom edge (resting thumb)", isOn: $thumbZone)
                    Text("Uses a private macOS framework. Place a finger and keep it still; moving first, a second finger, or clicking won't trigger.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let err = state.triggerError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Live text") {
                Picker("While speaking", selection: $live) {
                    ForEach(LiveMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.radioGroup)
                Picker("Without a selection", selection: $caret) {
                    ForEach(CaretPlacement.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Text("Holding on selected text always replaces that selection.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Speech") {
                Picker("Language", selection: $localeID) {
                    Text("System (\(Locale.current.identifier))").tag("")
                    ForEach(locales, id: \.identifier) { l in
                        Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
                    }
                }
                LabeledContent("On-device model") {
                    HStack {
                        Text(state.modelStatus).foregroundStyle(.secondary)
                        Button("Retry") { coordinator.ensureModel() }
                            .controlSize(.small)
                            .opacity(state.modelStatus.hasPrefix("Error") ? 1 : 0)
                    }
                }
                Toggle("Play start and stop sounds", isOn: $sounds)
            }

            Section("Permissions") {
                permissionRow("Accessibility", granted: state.accessibilityGranted,
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                permissionRow("Microphone", granted: state.microphone == .authorized,
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            let all = await DictationEngine.supportedLocales()
            locales = all.sorted { $0.identifier < $1.identifier }
        }
        .onAppear {
            coordinator.refreshPermissions()
            NSApp.activate()
        }
    }

    private func permissionRow(_ name: String, granted: Bool, url: String) -> some View {
        LabeledContent(name) {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open System Settings") { NSWorkspace.shared.open(URL(string: url)!) }
            }
        }
    }
}
