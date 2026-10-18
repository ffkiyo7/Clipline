import AppKit
import Carbon

/// A global shortcut through the Carbon hot key API. Unlike a global key
/// monitor, it needs no Accessibility permission. Each one has its own id:
/// the line's and the screenshot's.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handlerInstalled = false

    /// Nil when the combination cannot be registered, for example because
    /// another app already took it.
    init?(_ shortcut: Shortcut, id: UInt32 = 1, action: @escaping () -> Void) {
        // One handler for the app, however many shortcuts and changes.
        if !HotKey.handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                let id = pressed.id
                DispatchQueue.main.async { HotKey.actions[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
            HotKey.handlerInstalled = true
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x5445_4E44), id: id) // "TEND"
        let status = RegisterEventHotKey(UInt32(shortcut.keyCode), UInt32(shortcut.carbonModifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else { return nil }
        HotKey.actions[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
    }
}

/// The shortcut that shows and hides the line: ⌃⌥T unless changed, or none.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: NSEvent.ModifierFlags
    /// The key as typed, for the menu: "t", " ", "1".
    var key: String

    static let standard = Shortcut(keyCode: kVK_ANSI_T, modifiers: [.control, .option], key: "t")
    /// Clipline's own screenshot: ⌃⌥A unless changed.
    static let standardCapture = Shortcut(keyCode: kVK_ANSI_A, modifiers: [.control, .option], key: "a")

    /// The user's choice for the line. Nil means no shortcut at all.
    static var current: Shortcut? {
        get { load("shortcut", standard: standard) }
        set { store(newValue, "shortcut") }
    }

    /// The user's choice for taking a screenshot. Nil means none.
    static var capture: Shortcut? {
        get { load("captureShortcut", standard: standardCapture) }
        set { store(newValue, "captureShortcut") }
    }

    private static func load(_ defaultsKey: String, standard: Shortcut) -> Shortcut? {
        guard let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return standard }
        guard let code = saved["keyCode"] as? Int, let flags = saved["modifiers"] as? UInt,
              let key = saved["key"] as? String else { return nil }
        return Shortcut(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: flags), key: key)
    }

    private static func store(_ shortcut: Shortcut?, _ defaultsKey: String) {
        UserDefaults.standard.set(shortcut.map {
            ["keyCode": $0.keyCode, "modifiers": $0.modifiers.rawValue, "key": $0.key] as [String: Any]
        } ?? [:], forKey: defaultsKey)
    }

    /// From a key press, if it makes a usable global shortcut: it needs
    /// Command, Control or Option, so typing alone never triggers it.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty,
              let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: flags, key: key)
    }

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    var carbonModifiers: Int {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    /// As macOS writes it in menus: ⌃⌥⇧⌘ and the key.
    var display: String { symbols.joined() }

    /// Each modifier and the key on its own, for drawing them as keys.
    var symbols: [String] {
        Self.symbols(of: modifiers) + [key == " " ? L("Space") : key.uppercased()]
    }

    static func symbols(of modifiers: NSEvent.ModifierFlags) -> [String] {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }.map(\.1)
    }
}
