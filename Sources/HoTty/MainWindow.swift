import AVFoundation
import ServiceManagement
import Speech
import SwiftUI

/// Ready, paused, or something is off. Drives the sidebar card and the top-bar chip.
enum AppStatus { case ready, paused, broken }

@MainActor
func holdHint(_ trigger: String) -> String {
    trigger == TriggerMode.touchHold.rawValue
        ? "Rest a finger on the trackpad over any text field, then speak."
        : "Press and hold in any text field, then speak."
}

struct MainView: View {
    let coordinator: Coordinator
    let windows: Windows
    @Bindable var nav: Nav
    private var state: AppState { coordinator.state }
    private var store: Store { coordinator.store }

    private var status: AppStatus {
        if state.needsAttention { return .broken }
        return store.isPaused ? .paused : .ready
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(coordinator: coordinator, nav: nav, status: status)
                .frame(width: 224)
                .background(Theme.side)
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
            VStack(spacing: 0) {
                TopBar(title: nav.page.title, mic: state.micName, status: status)
                Rectangle().fill(Theme.line).frame(height: 1)
                TimelineView(.everyMinute) { _ in
                    page
                }
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .ignoresSafeArea()
        .onAppear { coordinator.refreshPermissions() }
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .home: ScrollView { HomePage(coordinator: coordinator, nav: nav, status: status).padding(.horizontal, 24).padding(.vertical, 20) }
        case .history: HistoryPage(store: store).padding(.horizontal, 24).padding(.vertical, 20)
        case .vocab: ScrollView { VocabPage(store: store).padding(.horizontal, 24).padding(.vertical, 20) }
        case .guide: ScrollView { GuidePage().padding(.horizontal, 24).padding(.vertical, 20) }
        case .news: ScrollView { NewsPage(store: store).padding(.horizontal, 24).padding(.vertical, 20) }
        case .settings: ScrollView { SettingsPage(coordinator: coordinator, windows: windows, nav: nav).padding(.horizontal, 24).padding(.vertical, 20) }
        }
    }
}

// MARK: - Chrome

private struct Sidebar: View {
    let coordinator: Coordinator
    @Bindable var nav: Nav
    let status: AppStatus
    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                AppIconImage(size: 30)
                Text("HoTty").font(.system(size: 16, weight: .bold))
            }
            .padding(.horizontal, 8)
            .padding(.top, 44)   // below the traffic lights
            .padding(.bottom, 14)

            ForEach(Page.allCases) { p in
                NavRow(page: p, selected: nav.page == p, dot: p == .news && coordinator.store.newsUnread) {
                    nav.page = p
                }
            }
            Spacer()
            statusCard
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
    }

    @ViewBuilder private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch status {
            case .ready:
                (Text("Ready. ").bold().foregroundStyle(Theme.text) + Text(holdHint(trigger)))
                    .font(.system(size: 13)).foregroundStyle(Theme.mute).lineSpacing(2)
                Button("Pause for 1 hour") { coordinator.pause() }
                    .buttonStyle(GhostButtonStyle())
                    .frame(maxWidth: .infinity)
            case .paused:
                (Text("Paused").bold().foregroundStyle(Theme.text)
                 + Text(" until \(coordinator.store.pausedUntil?.formatted(date: .omitted, time: .shortened) ?? ""). Holds won't start dictation."))
                    .font(.system(size: 13)).foregroundStyle(Theme.mute).lineSpacing(2)
                Button { coordinator.resume() } label: { Text("Resume now").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle())
            case .broken:
                (Text("Not working. ").bold().foregroundStyle(Theme.bad) + Text(brokenReason))
                    .font(.system(size: 13)).foregroundStyle(Theme.mute).lineSpacing(2)
                Button { nav.page = .settings; nav.tab = .permissions } label: { Text("Fix it").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var brokenReason: String {
        coordinator.state.accessibilityGranted
            ? "HoTty needs Microphone access to hear you."
            : "HoTty needs Accessibility access to type."
    }
}

private struct NavRow: View {
    let page: Page
    let selected: Bool
    let dot: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accText)
                    .frame(width: 20)
                Text(page.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                Spacer()
                if dot { Circle().fill(Theme.acc).frame(width: 8, height: 8) }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(selected ? Theme.sel : hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TopBar: View {
    let title: String
    let mic: String
    let status: AppStatus

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 18, weight: .bold))
            Spacer()
            Chip(text: mic, systemImage: "mic.fill", fg: Theme.text, bg: Theme.hover)
            switch status {
            case .ready: Chip(text: "Ready", fg: Theme.ok, bg: Theme.okBg, dot: true)
            case .paused: Chip(text: "Paused", fg: Theme.warn, bg: Theme.warnBg, dot: true)
            case .broken: Chip(text: "Needs attention", fg: Theme.bad, bg: Theme.badBg, dot: true)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
    }
}

/// Section label ("Your dictation").
private struct H2: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.mute)
    }
}

private extension Text {
    func lab() -> some View { font(.system(size: 12)).foregroundStyle(Theme.mute) }
}

private struct HLine: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

// MARK: - Home

private struct HomePage: View {
    let coordinator: Coordinator
    @Bindable var nav: Nav
    let status: AppStatus
    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue
    @State private var range = Store.Range.today
    @State private var loginOn = SMAppService.mainApp.status == .enabled
    private var store: Store { coordinator.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if status == .broken { warnBox }
            HStack {
                H2(store.history.isEmpty ? "Your dictation · numbers appear after your first few" : "Your dictation")
                Spacer()
                Segmented(selection: $range, options: [(.today, "Today"), (.week, "This week"), (.all, "All time")])
            }
            statsCard
            HStack(alignment: .top, spacing: 16) {
                tasksCard
                recentCard
            }
            .fixedSize(horizontal: false, vertical: true)
            if store.newsUnread { newsCard }
        }
        .onAppear {
            loginOn = SMAppService.mainApp.status == .enabled
            if loginOn { store.markDone(.login) }
        }
    }

    private var warnBox: some View {
        let ax = coordinator.state.accessibilityGranted
        return HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20)).foregroundStyle(Theme.bad)
            VStack(alignment: .leading, spacing: 2) {
                Text(ax ? "HoTty can't hear you" : "HoTty can't type into other apps")
                    .font(.system(size: 14, weight: .bold))
                Text(ax ? "Microphone access is off. Turn it on and dictation starts working again."
                        : "Accessibility access is off. Turn it on and dictation starts working again. \(AX.staleGrantHint)")
                    .font(.system(size: 13)).foregroundStyle(Theme.mute)
            }
            Spacer()
            Button("Open System Settings") { ax ? SystemSettings.microphone() : SystemSettings.accessibility() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.badBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.bad))
    }

    private var statsCard: some View {
        let s = store.stats(range)
        let cells: [(String, String)] = [
            (s.wpm.map(String.init) ?? "–", "Words per minute"),
            (s.words.formatted(), "Words dictated"),
            (minutesLabel(s.savedMinutes), "Time saved vs typing"),
            ("\(s.apps)", "Apps used"),
        ]
        return HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { i in
                if i > 0 { Rectangle().fill(Theme.line).frame(width: 1) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(cells[i].0).font(.system(size: 26, weight: .bold)).monospacedDigit()
                    Text(cells[i].1).lab().lineLimit(1)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .card()
    }

    private struct TaskInfo { let id: Task4; let title: String; let desc: String; let key: String }
    private let tasks = [
        TaskInfo(id: .free, title: "Try hands-free", desc: "Drag up while holding, then keep talking", key: "↑"),
        TaskInfo(id: .send, title: "Send a message by voice", desc: "Drag right before letting go in a chat app", key: "→"),
        TaskInfo(id: .word, title: "Add a custom word", desc: "Teach HoTty a name or term it gets wrong", key: "Vocabulary"),
        TaskInfo(id: .login, title: "Open HoTty at login", desc: "So it is ready after every restart", key: "Settings"),
    ]

    private func isDone(_ t: Task4) -> Bool { t == .login ? loginOn || store.tasksDone.contains(.login) : store.tasksDone.contains(t) }

    private var tasksCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Get started").font(.system(size: 14, weight: .bold))
                Spacer()
                Text("\(tasks.filter { isDone($0.id) }.count) of 4 done").lab()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            ForEach(tasks, id: \.id) { t in
                HLine()
                RowButton {
                    switch t.id {
                    case .free, .send: nav.page = .guide
                    case .word: nav.page = .vocab
                    case .login: nav.page = .settings; nav.tab = .general
                    }
                } label: {
                    HStack(spacing: 12) {
                        CheckDot(done: isDone(t.id))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.title).font(.system(size: 14, weight: .semibold))
                                .strikethrough(isDone(t.id), color: Theme.mute)
                            Text(t.desc).lab().lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Chip(text: t.key)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recentCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent").font(.system(size: 14, weight: .bold))
                Spacer()
                if !store.history.isEmpty {
                    Button("See all") { nav.page = .history }.buttonStyle(LinkButtonStyle())
                }
            }
            .padding(.leading, 16).padding(.trailing, 12)
            .frame(minHeight: 44)
            if store.history.isEmpty {
                HLine()
                VStack(spacing: 8) {
                    ArrowTile(text: "↓")
                    Text("No dictations yet").font(.system(size: 14, weight: .semibold))
                    Text("\(holdHint(trigger)) Your words show up here.")
                        .lab().multilineTextAlignment(.center).frame(maxWidth: 260)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ForEach(store.history.prefix(4)) { d in
                    HLine()
                    HStack(spacing: 12) {
                        AppBadge(name: d.app, bundleID: d.bundleID)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(d.app).font(.system(size: 13, weight: .bold))
                                Text(relativeWhen(d.date)).lab()
                            }
                            Text(d.text.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 13)).foregroundStyle(Theme.mute).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if d.sent { Chip(text: "↵ Sent") }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .card()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var newsCard: some View {
        HStack(spacing: 14) {
            Chip(text: "What's new")
            VStack(alignment: .leading, spacing: 2) {
                Text("Hands-free mode").font(.system(size: 14, weight: .semibold))
                Text("Drag up while holding, let go and keep talking. Sessions now survive plugging in headphones.")
                    .lab().lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("See what changed") { nav.page = .news }.buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .card()
    }
}

/// A full-width row that highlights on hover.
private struct RowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? Theme.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - History

private struct HistoryPage: View {
    let store: Store
    @State private var query = ""
    @State private var copied: UUID?
    @State private var confirmClear = false

    private var hits: [Dictation] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.history }
        return store.history.filter { $0.text.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                InputField(placeholder: "Search dictations", text: $query, icon: "magnifyingglass")
                Text("Stored only on this Mac").lab().fixedSize()
                Button("Clear history") { confirmClear = true }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(store.history.isEmpty)
            }
            let list = hits
            ScrollView {
                LazyVStack(spacing: 0) {
                    if list.isEmpty {
                        Text(store.history.isEmpty
                             ? "Nothing here yet. Your dictations are listed here after you let go."
                             : "No dictations match \"\(query)\".")
                            .font(.system(size: 14)).foregroundStyle(Theme.mute)
                            .padding(28).frame(maxWidth: .infinity)
                    }
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, d in
                        if i > 0 { HLine() }
                        row(d)
                    }
                }
                .card()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .scrollIndicators(.automatic)
        }
        .alert("Clear all dictation history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { store.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every saved dictation from this Mac. Your stats reset too.")
        }
    }

    private func row(_ d: Dictation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AppBadge(name: d.app, bundleID: d.bundleID)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(d.app).font(.system(size: 13, weight: .bold))
                    Text("\(relativeWhen(d.date)) · \(d.words) word\(d.words == 1 ? "" : "s")").lab()
                    if d.sent { Chip(text: "↵ Sent") }
                }
                Text(d.text).font(.system(size: 14)).lineLimit(3).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(copied == d.id ? "Copied" : "Copy") { copy(d) }
                .buttonStyle(GhostButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .contextMenu {
            Button("Copy") { copy(d) }
            Button("Delete", role: .destructive) { store.delete(d) }
        }
    }

    private func copy(_ d: Dictation) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(d.text, forType: .string)
        copied = d.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == d.id { copied = nil } }
    }
}

/// 38 pt text field with the design's border.
struct InputField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).foregroundStyle(Theme.mute) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.line))
    }
}

// MARK: - Vocabulary

private struct VocabPage: View {
    let store: Store
    @State private var draft = ""
    @State private var say = ""
    @State private var type = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HoTty spells these exactly as written. Add names, products and jargon the speech model gets wrong.")
                .font(.system(size: 14)).foregroundStyle(Theme.mute).lineSpacing(3).frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: 8) {
                InputField(placeholder: "Add a word or name", text: $draft, onSubmit: add).frame(width: 320)
                Button("Add", action: add).buttonStyle(PrimaryButtonStyle(height: 38))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            FlowLayout(spacing: 8) {
                ForEach(store.words, id: \.self) { w in
                    HStack(spacing: 4) {
                        Text(w).font(.system(size: 14, weight: .semibold))
                        Button { store.removeWord(w) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.mute).frame(width: 26, height: 26).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(w)")
                    }
                    .padding(.leading, 12).padding(.trailing, 4)
                    .frame(height: 34)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line))
                }
            }
            Text("\(store.words.count) word\(store.words.count == 1 ? "" : "s") · used for every language").lab()

            VStack(alignment: .leading, spacing: 10) {
                Text("Replacements").font(.system(size: 14, weight: .bold))
                Text("When HoTty hears the phrase on the left, it types the text on the right.").lab()
                ForEach(store.replacements) { r in
                    HStack(spacing: 12) {
                        Text("\"\(r.say)\"").foregroundStyle(Theme.mute).frame(width: 200, alignment: .leading)
                        Text("→").foregroundStyle(Theme.mute)
                        replacementLabel(r.type)
                        Spacer()
                        Button { store.removeReplacement(r) } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.mute).frame(width: 26, height: 26).contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(r.say)")
                    }
                    .font(.system(size: 14))
                }
                HStack(spacing: 8) {
                    InputField(placeholder: "When I say…", text: $say).frame(width: 200)
                    Text("→").foregroundStyle(Theme.mute)
                    InputField(placeholder: "Type this (\\n for a new line)", text: $type, onSubmit: addReplacement)
                    Button("Add", action: addReplacement).buttonStyle(GhostButtonStyle(height: 38))
                        .disabled(say.trimmingCharacters(in: .whitespaces).isEmpty || type.isEmpty)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    @ViewBuilder private func replacementLabel(_ t: String) -> some View {
        switch t {
        case "\n": Text("line break").italic().foregroundStyle(Theme.mute)
        case "\n\n": Text("blank line").italic().foregroundStyle(Theme.mute)
        default: Text(t.replacingOccurrences(of: "\n", with: "⏎")).fontWeight(.semibold)
        }
    }

    private func add() {
        if store.addWord(draft) { draft = "" }
    }

    private func addReplacement() {
        store.addReplacement(say: say, type: type.replacingOccurrences(of: "\\n", with: "\n"))
        say = ""; type = ""
    }
}

/// Wraps children onto new lines, left-aligned.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(bounds.width, subviews)
        for (i, p) in rows.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            points.append(CGPoint(x: x, y: y))
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x - spacing)
        }
        return (points, maxW, y + rowH)
    }
}

// MARK: - Gestures guide

struct GestureInfo: Identifiable {
    let id: String
    let arrow: String
    let title: String
    let desc: String
    let dirWord: String
    let badge: String
    let color: Color?
    let after: String

    static let all = [
        GestureInfo(id: "down", arrow: "↓", title: "Let go, or drag down: insert",
                    desc: "Your words are typed where you held. This is what happens if you don’t drag at all.",
                    dirWord: "down", badge: "", color: nil, after: "No badge: letting go types the text."),
        GestureInfo(id: "right", arrow: "→", title: "Drag right: send",
                    desc: "Types your words and presses Return. Made for chats, search boxes and prompts.",
                    dirWord: "right", badge: "↵ Send", color: Theme.send, after: "Letting go types the text, then presses Return."),
        GestureInfo(id: "left", arrow: "←", title: "Drag left: cancel",
                    desc: "Throws the dictation away. Nothing is typed.",
                    dirWord: "left", badge: "✕ Cancel", color: Theme.cancel, after: "Letting go discards the text."),
        GestureInfo(id: "up", arrow: "↑", title: "Drag up: hands-free",
                    desc: "Let go and keep talking. Finish, send or cancel from the buttons on the overlay.",
                    dirWord: "up", badge: "Lock", color: Theme.indigo, after: "Letting go keeps HoTty listening until you press Finish."),
    ]
}

private struct GuidePage: View {
    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue
    @State private var pick = "down"

    var body: some View {
        let g = GestureInfo.all.first { $0.id == pick }!
        VStack(alignment: .leading, spacing: 16) {
            Text("\(holdHint(trigger)) While you hold, drag a finger's width in one direction to choose what happens when you let go.")
                .font(.system(size: 14)).foregroundStyle(Theme.mute).lineSpacing(3).frame(maxWidth: 640, alignment: .leading)
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { card(GestureInfo.all[0]); card(GestureInfo.all[1]) }
                GridRow { card(GestureInfo.all[2]); card(GestureInfo.all[3]) }
            }
            VStack(alignment: .leading, spacing: 12) {
                Text("What you see while dragging \(g.dirWord)").lab()
                OverlaySample(text: "Running ten minutes late, start without me.", badge: g.badge, color: g.color,
                              struck: g.id == "left")
                Text(g.after).lab()
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }

    private func card(_ g: GestureInfo) -> some View {
        let on = pick == g.id
        return Button { pick = g.id } label: {
            HStack(alignment: .top, spacing: 14) {
                ArrowTile(text: g.arrow)
                VStack(alignment: .leading, spacing: 4) {
                    Text(g.title).font(.system(size: 15, weight: .bold))
                    Text(g.desc).font(.system(size: 13)).foregroundStyle(Theme.mute).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(on ? Theme.acc : Theme.line, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A static copy of the dictation overlay, for guides.
struct OverlaySample: View {
    let text: String
    var badge = ""
    var color: Color? = nil
    var struck = false

    var body: some View {
        HStack(spacing: 10) {
            MeterGlyph()
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color(nsColor: NSColor(hex: 0x1d1d1f)).opacity(struck ? 0.4 : 0.88))
                .strikethrough(struck, color: Theme.cancel.opacity(0.6))
            if !badge.isEmpty, let color { GestureBadge(text: badge, color: color) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(nsColor: NSColor(hex: 0xf7f7f8)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(color?.opacity(0.7) ?? .black.opacity(0.08), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
    }
}

// MARK: - What's new

private struct NewsPage: View {
    let store: Store

    private struct Entry { let ver: String; let title: String; let items: [String] }
    private let entries = [
        Entry(ver: "Update 4", title: "Hands-free mode", items: [
            "Drag up while holding, let go and keep talking.",
            "Finish, send or cancel from the overlay, with a running timer.",
            "Dictation keeps going when you plug in headphones or switch microphones.",
        ]),
        Entry(ver: "Update 3", title: "External trackpads", items: [
            "Rest-finger mode now works with Magic Trackpad, not just the built-in one.",
        ]),
        Entry(ver: "Update 2", title: "Release gestures", items: [
            "Drag right before letting go to send.",
            "Drag left to cancel without typing anything.",
        ]),
        Entry(ver: "Update 1", title: "Hello, HoTty", items: [
            "Hold anywhere you can type, speak, let go.",
            "Runs fully on this Mac with Apple’s speech model.",
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries.indices, id: \.self) { i in
                let e = entries[i]
                if i > 0 { HLine() }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e.ver).font(.system(size: 14, weight: .bold))
                        if i == 0 { Chip(text: "Latest") }
                    }
                    .frame(width: 120, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(e.title).font(.system(size: 15, weight: .bold))
                        ForEach(e.items, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                Text(item)
                            }
                            .font(.system(size: 13)).foregroundStyle(Theme.mute)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            }
        }
        .card()
        .onAppear { store.markNewsSeen() }
    }
}

// MARK: - Settings

private struct SettingsPage: View {
    let coordinator: Coordinator
    let windows: Windows
    @Bindable var nav: Nav

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Segmented(selection: $nav.tab, options: [(.dictation, "Dictation"), (.general, "General"), (.permissions, "Permissions")])
            switch nav.tab {
            case .dictation: DictationSettings(coordinator: coordinator)
            case .general: GeneralSettings(coordinator: coordinator, windows: windows)
            case .permissions: PermissionSettings(coordinator: coordinator)
            }
        }
    }
}

/// One settings row: title and explanation on the left, a control on the right.
private struct SetRow<Control: View>: View {
    let title: String
    let sub: String
    var first = false
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            if !first { HLine() }
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(sub).font(.system(size: 12)).foregroundStyle(Theme.mute)
                }
                Spacer(minLength: 8)
                control()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(minHeight: 60)
        }
    }
}

private struct DictationSettings: View {
    let coordinator: Coordinator
    @AppStorage(Pref.triggerMode) private var trigger = TriggerMode.clickHold.rawValue
    @AppStorage(Pref.liveMode) private var live = LiveMode.overlay.rawValue
    @AppStorage(Pref.caretPlacement) private var caret = CaretPlacement.atPointer.rawValue
    @AppStorage(Pref.holdDuration) private var hold = 0.4
    @AppStorage(Pref.ignoreThumbZone) private var thumbZone = true

    var body: some View {
        VStack(spacing: 0) {
            SetRow(title: "Hold gesture", sub: "How a dictation starts", first: true) {
                Segmented(selection: $trigger, options: [(TriggerMode.clickHold.rawValue, "Press & hold"),
                                                         (TriggerMode.touchHold.rawValue, "Rest finger")])
            }
            if trigger == TriggerMode.touchHold.rawValue {
                SetRow(title: "Ignore a resting thumb", sub: "Touches along the bottom edge of the trackpad won't start dictation") {
                    PillSwitch(isOn: $thumbZone)
                }
            }
            if let err = coordinator.state.triggerError {
                SetRow(title: "Hold detection is off", sub: err) {
                    Button("Try again") { coordinator.applyTrigger() }.buttonStyle(GhostButtonStyle())
                }
            }
            SetRow(title: "Start listening after", sub: "Longer means fewer accidental starts") {
                Slider(value: $hold, in: Pref.holdDurationRange, step: 0.05).frame(width: 180).tint(Theme.acc)
                Text(String(format: "%.2f s", hold)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            SetRow(title: "While speaking", sub: live == LiveMode.overlay.rawValue
                   ? "Words show in a bubble, then get typed when you let go"
                   : "Words are typed into the field as you speak") {
                Segmented(selection: $live, options: [(LiveMode.overlay.rawValue, "Preview overlay"), (LiveMode.inline.rawValue, "Type live")])
            }
            SetRow(title: "Where words go", sub: "Holding on selected text always replaces it") {
                Segmented(selection: $caret, options: [(CaretPlacement.atPointer.rawValue, "Where I hold"),
                                                       (CaretPlacement.existing.rawValue, "Current cursor")])
            }
        }
        .card()
    }
}

/// Language picker over the locales the speech model supports.
struct LanguagePicker: View {
    @AppStorage(Pref.localeID) private var localeID = ""
    @AppStorage(Pref.speechEngine) private var engine = SpeechEngine.apple.rawValue
    @State private var locales: [Locale] = []
    var width: CGFloat = 270

    /// "English (United States)", without region overrides like "@rg=inzzzz".
    static var systemName: String {
        let id = Locale.current.identifier.split(separator: "@").first.map(String.init) ?? Locale.current.identifier
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }

    var body: some View {
        if engine == SpeechEngine.phonon.rawValue {
            Picker("Language", selection: .constant("en")) { Text("English").tag("en") }
                .labelsHidden()
                .frame(width: width)
                .disabled(true)
        } else {
            localePicker
        }
    }

    private var localePicker: some View {
        Picker("Language", selection: $localeID) {
            Text("System — \(Self.systemName)").tag("")
            Divider()
            ForEach(locales, id: \.identifier) { l in
                Text(Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier).tag(l.identifier)
            }
        }
        .labelsHidden()
        .frame(width: width)
        .task {
            let all = await DictationEngine.supportedLocales()
            locales = all.sorted {
                (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                    < (Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier)
            }
        }
    }
}

/// "Speech model ready · works offline" and friends.
@MainActor
func modelLine(_ m: DictationEngine.ModelState) -> String {
    switch m {
    case .checking: "Checking the speech model…"
    case .downloading(let f): "Downloading speech model · \(Int(f * 100))%"
    case .preparing(let s): s
    case .ready: "Speech model ready · works offline"
    case .failed(let e): "Speech model unavailable: \(e)"
    }
}

private struct GeneralSettings: View {
    let coordinator: Coordinator
    let windows: Windows
    @AppStorage(Pref.micUIDKey) private var micUID = ""
    @AppStorage(Pref.playSounds) private var sounds = true
    @AppStorage(Pref.speechEngine) private var engine = SpeechEngine.apple.rawValue
    @State private var login = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var mics: [Microphones.Device] = []

    var body: some View {
        VStack(spacing: 0) {
            SetRow(title: "Speech recognition", sub: engineSub, first: true) {
                Picker("Speech recognition", selection: $engine) {
                    ForEach(SpeechEngine.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 230)
            }
            if phononMissing {
                SetRow(title: "Install Phonon-2", sub: "Build the model with scripts/convert-phonon.sh, then press Retry") {
                    Button("Show folder") {
                        let dir = PhononModel.directory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                    .buttonStyle(GhostButtonStyle())
                }
            }
            SetRow(title: "Language", sub: modelLine(coordinator.state.model)) {
                if case .failed = coordinator.state.model {
                    Button("Retry") { coordinator.ensureModel() }.buttonStyle(GhostButtonStyle())
                }
                LanguagePicker()
            }
            SetRow(title: "Microphone", sub: micUID.isEmpty ? "Switches automatically when you plug in headphones"
                   : "Falls back to the system default when unplugged") {
                Picker("Microphone", selection: $micUID) {
                    Text("System default").tag("")
                    Divider()
                    ForEach(mics) { Text($0.name).tag($0.id) }
                    if !micUID.isEmpty && !mics.contains(where: { $0.id == micUID }) {
                        Text("Unplugged microphone").tag(micUID)
                    }
                }
                .labelsHidden()
                .frame(width: 230)
            }
            SetRow(title: "Start and stop sounds", sub: "A short tone when listening begins and ends") {
                PillSwitch(isOn: $sounds)
            }
            SetRow(title: "Open at login", sub: loginError ?? "Keep HoTty ready after a restart") {
                PillSwitch(isOn: $login)
            }
            SetRow(title: "Onboarding", sub: "Walk through setup and practice again") {
                Button("Run again") { windows.showOnboarding() }.buttonStyle(GhostButtonStyle())
            }
        }
        .card()
        .onAppear { mics = Microphones.all() }
        .onChange(of: micUID) { _, _ in coordinator.refreshPermissions() }
        .onChange(of: login) { _, on in
            loginError = setLoginItem(on)
            login = SMAppService.mainApp.status == .enabled
            if login { coordinator.store.markDone(.login) }
        }
    }
}

private extension GeneralSettings {
    var engineSub: String {
        engine == SpeechEngine.phonon.rawValue
            ? "Fermion Research's Phonon-2, on this Mac through Core ML"
            : "Apple's on-device model, in many languages"
    }

    var phononMissing: Bool {
        guard engine == SpeechEngine.phonon.rawValue, case .failed(let e) = coordinator.state.model else { return false }
        return e.hasPrefix("The Phonon-2 model isn't installed")
    }
}

/// Registers or removes HoTty as a login item; returns an error message on failure.
@MainActor
func setLoginItem(_ on: Bool) -> String? {
    do {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        return nil
    } catch {
        return "Couldn't change: \(error.localizedDescription)"
    }
}

private struct PermissionSettings: View {
    let coordinator: Coordinator
    private var state: AppState { coordinator.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Everything is processed on this Mac. HoTty never sends audio or text anywhere.")
                .font(.system(size: 14)).foregroundStyle(Theme.mute).frame(maxWidth: 600, alignment: .leading)
            VStack(spacing: 0) {
                row("M", "Microphone", "To hear you while you hold", first: true,
                    ok: state.microphone == .authorized, undetermined: state.microphone == .notDetermined,
                    ask: {
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                            coordinator.refreshPermissions()
                        }
                    }, open: SystemSettings.microphone)
                row("S", "Speech recognition", "To turn speech into text, on this Mac",
                    ok: state.speech == .authorized, undetermined: state.speech == .notDetermined,
                    ask: {
                        SFSpeechRecognizer.requestAuthorization { _ in
                            DispatchQueue.main.async { coordinator.refreshPermissions() }
                        }
                    }, open: SystemSettings.speech)
                row("A", "Accessibility", state.accessibilityGranted ? "To notice holds and type into other apps" : AX.staleGrantHint,
                    ok: state.accessibilityGranted, undetermined: false, ask: {}, open: SystemSettings.accessibility)
            }
            .card()
        }
        .onAppear { coordinator.refreshPermissions() }
    }

    private func row(_ letter: String, _ name: String, _ why: String, first: Bool = false, ok: Bool,
                     undetermined: Bool, ask: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            if !first { HLine() }
            HStack(spacing: 16) {
                ArrowTile(text: letter, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                    Text(why).font(.system(size: 12)).foregroundStyle(Theme.mute)
                }
                Spacer()
                if ok {
                    Chip(text: "Allowed", systemImage: "checkmark", fg: Theme.ok, bg: Theme.okBg)
                } else if undetermined {
                    Chip(text: "Not asked yet", fg: Theme.warn, bg: Theme.warnBg)
                    Button("Allow", action: ask).buttonStyle(PrimaryButtonStyle())
                } else {
                    Chip(text: "Off", fg: Theme.bad, bg: Theme.badBg)
                    Button("Open System Settings", action: open).buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(minHeight: 60)
        }
    }
}
