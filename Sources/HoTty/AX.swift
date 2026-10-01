import AppKit
import ApplicationServices

/// Thin wrappers over the Accessibility C API. All points are in global CG
/// coordinates (origin top-left of the primary display), which is what AX uses.
enum AX {
    static let systemWide = AXUIElementCreateSystemWide()
    static let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Roles we treat as a place text can be typed into.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func paramAttr<T>(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &v) == .success else { return nil }
        return v as? T
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    static func range(_ el: AXUIElement) -> CFRange? {
        guard let v: AXValue = attrValue(el, kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange()
        return AXValueGetValue(v, .cfRange, &r) ? r : nil
    }

    private static func attrValue(_ el: AXUIElement, _ name: String) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    /// Hit-tests the screen and walks up a few levels to find an editable text element.
    /// `timeout` bounds how long a hung app can block us (seconds).
    static func editableElement(at p: CGPoint, timeout: Float = 0.25) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(systemWide, timeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success,
              var el = hit else { return nil }
        guard pid(el) != ownPID else { return nil }
        AXUIElementSetMessagingTimeout(el, timeout)

        // Web content: WebKit and Chromium point at the editable root directly.
        if let editable = element(el, "AXEditableAncestor") {
            return isSecure(editable) ? nil : editable
        }
        let hitElement = el
        for _ in 0..<6 {
            if isTextElement(el) { return isSecure(el) ? nil : el }
            guard let parent = element(el, kAXParentAttribute) else { break }
            el = parent
        }
        // Chromium's own UI (e.g. Edge's address bar) hit-tests to a container, not the field.
        if let f = focusedElement, isTextElement(f), frame(f)?.contains(p) == true {
            return isSecure(f) ? nil : f
        }
        if let found = descendantTextElement(of: hitElement, containing: p) {
            return isSecure(found) ? nil : found
        }
        return nil
    }

    private static func isTextElement(_ el: AXUIElement) -> Bool {
        guard let role: String = attr(el, kAXRoleAttribute) else { return false }
        return textRoles.contains(role)
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    /// Breadth-first search below `root` through children whose frames contain `p`,
    /// capped so a huge tree can't stall us.
    private static func descendantTextElement(of root: AXUIElement, containing p: CGPoint) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 150 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            guard depth < 8, let children: [AXUIElement] = attr(el, kAXChildrenAttribute) else { continue }
            for c in children where frame(c)?.insetBy(dx: -2, dy: -2).contains(p) == true {
                if isTextElement(c) { return c }
                queue.append((c, depth + 1))
            }
        }
        return nil
    }

    static func isSecure(_ el: AXUIElement) -> Bool {
        (attr(el, kAXSubroleAttribute) as String?) == kAXSecureTextFieldSubrole
    }

    /// True when `el` has a non-empty selection whose on-screen bounds contain `p`.
    /// If the app has a selection but can't report its bounds, we assume the hold
    /// is on it: the user is pressing inside a field that visibly has a selection.
    static func selectionContains(_ el: AXUIElement, _ p: CGPoint) -> Bool {
        if let r = range(el) {
            guard r.length > 0 else { return false }
            var rr = r
            if let rv = AXValueCreate(.cfRange, &rr),
               let bv: AXValue = paramValue(el, kAXBoundsForRangeParameterizedAttribute, rv) {
                var rect = CGRect.zero
                if AXValueGetValue(bv, .cgRect, &rect), !rect.isEmpty {
                    return rect.insetBy(dx: -3, dy: -3).contains(p)
                }
            }
            return true
        }
        // No range attribute (some web editors): fall back to selected text.
        let text: String? = attr(el, kAXSelectedTextAttribute)
        return !(text ?? "").isEmpty
    }

    private static func paramValue(_ el: AXUIElement, _ name: String, _ param: CFTypeRef) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, name as CFString, param, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }

    static func selectedText(_ el: AXUIElement) -> String {
        attr(el, kAXSelectedTextAttribute) ?? ""
    }

    /// True if `a` and `b` are the same element or one contains the other (within a few
    /// levels). Web views sometimes report the editable root on one side and an inner
    /// element on the other.
    static func isSameOrRelated(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        func contains(_ outer: AXUIElement, _ inner: AXUIElement) -> Bool {
            var el: AXUIElement? = inner
            for _ in 0..<5 {
                guard let e = el else { return false }
                if CFEqual(e, outer) { return true }
                el = element(e, kAXParentAttribute)
            }
            return false
        }
        return contains(a, b) || contains(b, a)
    }

    static var focusedElement: AXUIElement? {
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        return element(systemWide, kAXFocusedUIElementAttribute)
    }

    /// Up to `max` characters just before the caret (or selection) in the focused element,
    /// used to decide leading spaces and capitalization. "" at the start of a field,
    /// nil if the app doesn't say.
    static func textBeforeCaret(max: Int = 16) -> String? {
        guard let el = focusedElement, let r = range(el) else { return nil }
        guard r.location > 0 else { return "" }
        let len = min(max, r.location)
        var prev = CFRange(location: r.location - len, length: len)
        if let pv = AXValueCreate(.cfRange, &prev),
           let s: String = paramAttr(el, kAXStringForRangeParameterizedAttribute, pv) {
            return s
        }
        if let value: String = attr(el, kAXValueAttribute) {
            let u = Array(value.utf16)
            guard r.location <= u.count else { return nil }
            return String(decoding: u[(r.location - len)..<r.location], as: UTF16.self)
        }
        return nil
    }

    /// Brings the element's app and window forward and focuses the element, without
    /// clicking (a click would collapse the selection we are about to replace).
    static func focus(_ el: AXUIElement) {
        let p = pid(el)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != p {
            NSRunningApplication(processIdentifier: p)?.activate()
            if let win = element(el, kAXWindowAttribute) {
                AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
        }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Chromium-based apps only build an accessibility tree for their web content when asked.
    /// Electron apps take `AXManualAccessibility`. Apps embedding Chromium another way (ChatGPT's
    /// web view, say) refuse that and need `AXEnhancedUserInterface`, which is reserved for them:
    /// in ordinary apps it changes window behavior (animations, window managers).
    static func enableWebAccessibility(_ app: NSRunningApplication) {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let manual = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard manual == .attributeUnsupported, embedsChromium(app.bundleURL) else { return }
        // Chromium reports an error here but applies it; the tree follows a moment later.
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    private static var chromiumBundles: [URL: Bool] = [:]

    /// Whether a bundle ships Chromium: a framework with Chromium's crash handler in its Helpers.
    private static func embedsChromium(_ bundle: URL?) -> Bool {
        guard let bundle else { return false }
        if let known = chromiumBundles[bundle] { return known }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        var found = false
        let fm = FileManager.default
        for fw in (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? [] where fw.hasSuffix(".framework") {
            let versions = frameworks.appendingPathComponent("\(fw)/Versions")
            let dirs = ((try? fm.contentsOfDirectory(atPath: versions.path)) ?? []).map { versions.appendingPathComponent("\($0)/Helpers") }
                + [frameworks.appendingPathComponent("\(fw)/Helpers")]
            if dirs.contains(where: { ((try? fm.contentsOfDirectory(atPath: $0.path)) ?? []).contains { $0.hasSuffix("crashpad_handler") } }) {
                found = true
                break
            }
        }
        chromiumBundles[bundle] = found
        return found
    }

    /// Diagnostic: role chain from the element under `p` up to the window, plus the focused element.
    static func describe(at p: CGPoint) -> String {
        var hit: AXUIElement?
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &hit) == .success, var el = hit else {
            return "no element at \(p)"
        }
        var parts: [String] = []
        for _ in 0..<8 {
            let role: String = attr(el, kAXRoleAttribute) ?? "?"
            let sub: String = attr(el, kAXSubroleAttribute) ?? ""
            let editable = element(el, "AXEditableAncestor") != nil ? " [editableAncestor]" : ""
            parts.append(role + (sub.isEmpty ? "" : "/\(sub)") + editable)
            if role == kAXWindowRole { break }
            guard let parent = element(el, kAXParentAttribute) else { break }
            el = parent
        }
        let f = focusedElement
        let fRole: String = f.flatMap { attr($0, kAXRoleAttribute) } ?? "none"
        return "pid \(pid(hit!)) chain: " + parts.joined(separator: " < ") + " | focused: \(fRole) | editable: \(editableElement(at: p) != nil)"
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system's Accessibility prompt, which also adds HoTTy to the list in System
    /// Settings. Only once per build: after that HoTTy is already in the list, and another prompt
    /// can't help. A switch that is on but doesn't take (a grant saved for a different signature of
    /// the same app) needs HoTTy removed from the list and added again; see `staleGrantHint`.
    static func promptForTrust() {
        let build = "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "")-\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "")"
        guard UserDefaults.standard.string(forKey: promptedKey) != build else { return }
        UserDefaults.standard.set(build, forKey: promptedKey)
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static let promptedKey = "accessibilityPromptedBuild"

    static let staleGrantHint = "Already switched on? Select HoTTy in the list, remove it with −, then add it again with +."
}

/// Converts between CG global coordinates (top-left origin) and Cocoa screen coordinates.
enum ScreenGeometry {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func cocoa(fromCG p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: primaryHeight - p.y) }
    static func cg(fromCocoa p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primaryHeight - p.y) }
    static var mouseCG: CGPoint { cg(fromCocoa: NSEvent.mouseLocation) }
}
