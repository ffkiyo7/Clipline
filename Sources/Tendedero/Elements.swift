import AppKit
import ApplicationServices

/// The parts of a window under the pointer, read through Accessibility: a
/// button, a sidebar, a text area. While taking a screenshot they light up
/// like windows do, and scrolling steps out to the part that holds them.
///
/// It needs Accessibility access, which the user turns on from the menu.
/// Without it, screenshots still find whole windows.
enum Elements {
    private static let enabledKey = "detectElements"

    /// The user's choice. Off until turned on, since it asks for access.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Whether it runs: chosen, and allowed.
    static var isActive: Bool { isEnabled && isTrusted }

    /// Turning it on asks macOS for access the first time; the system shows
    /// its own prompt, and the user decides in System Settings.
    static func askForAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// One part of a window, in AppKit screen coordinates.
    struct Element: Equatable {
        let frame: CGRect
        /// What the system calls it, like "button", in the user's language.
        let kind: String?
    }

    /// Apps built on Chromium, like Electron apps, only describe their
    /// contents once asked to; the first look may still find nothing.
    static func wake(_ pids: Set<pid_t>) {
        for pid in pids {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                         "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    /// The parts under a point, innermost first, each larger than the last
    /// and inside `window`. The window itself is not among them.
    /// `top`: the top of the main screen, which Accessibility measures from.
    nonisolated static func chain(at p: CGPoint, pid: pid_t, window: CGRect, top: CGFloat) -> [Element] {
        let app = AXUIElementCreateApplication(pid)
        // A frozen app must not freeze the screenshot.
        AXUIElementSetMessagingTimeout(app, 0.1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(top - p.y), &hit) == .success,
              var element = hit else { return [] }

        var chain: [Element] = []
        for _ in 0..<40 {
            let role = string(element, kAXRoleAttribute)
            if role == kAXWindowRole || role == kAXApplicationRole { break }
            if let frame = frame(of: element, top: top)?.intersection(window), !frame.isNull,
               frame.width >= 6, frame.height >= 6,
               frame.width < window.width - 1 || frame.height < window.height - 1,
               frame.contains(p),
               chain.last.map({ frame.contains($0.frame) && frame != $0.frame }) ?? true {
                chain.append(Element(frame: frame, kind: string(element, kAXRoleDescriptionAttribute)))
            }
            guard let parent = value(element, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return chain
    }

    nonisolated private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    nonisolated private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    /// Accessibility measures from the top of the main screen.
    nonisolated private static func frame(of element: AXUIElement, top: CGFloat) -> CGRect? {
        guard let position = axValue(element, kAXPositionAttribute),
              let size = axValue(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(x: origin.x, y: top - origin.y - extent.height, width: extent.width, height: extent.height)
    }
}
