import AppKit
import Carbon
import SwiftUI

/// The two global shortcuts, the line's and the screenshot's: what they are,
/// keeping them registered, and recording new ones. Every field that shows
/// one, in the shortcuts window or the welcome, watches this.
@MainActor
final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()

    enum Kind: CaseIterable {
        case line, capture

        var standard: Shortcut {
            switch self {
            case .line: .standard
            case .capture: .standardCapture
            }
        }

        var title: String {
            switch self {
            case .line: L("Show or hide the line")
            case .capture: L("Take Screenshot")
            }
        }

        var detail: String {
            switch self {
            case .line: L("Brings the line down, or puts it away.")
            case .capture: L("Freezes the screen so you can pick a window or an area.")
            }
        }

        fileprivate var id: UInt32 {
            switch self {
            case .line: 1
            case .capture: 2
            }
        }
    }

    @Published private(set) var line = Shortcut.current
    @Published private(set) var capture = Shortcut.capture
    /// The field waiting for keys, if any.
    @Published private(set) var recording: Kind?
    /// The modifiers held down while recording, shown before the key comes.
    @Published private(set) var held: NSEvent.ModifierFlags = []
    /// Why the last keys pressed could not become the shortcut.
    @Published private(set) var problem: String?

    /// What each shortcut does, set once by the app.
    var actions: [Kind: () -> Void] = [:]

    private var keys: [Kind: HotKey] = [:]
    private var paused = false
    private var monitor: Any?

    func shortcut(for kind: Kind) -> Shortcut? {
        kind == .line ? line : capture
    }

    /// Registers both, unless a menu is open or keys are being recorded:
    /// then pressing a shortcut should reach the menu or the recording.
    func register() {
        keys = [:]
        guard !paused, recording == nil else { return }
        for kind in Kind.allCases {
            guard let shortcut = shortcut(for: kind), let action = actions[kind] else { continue }
            keys[kind] = HotKey(shortcut, id: kind.id, action: action)
            if keys[kind] == nil {
                log.error("The shortcut \(shortcut.display, privacy: .public) is taken by another app")
            }
        }
    }

    /// While the menu bar menu is open, macOS holds a hot key back until it
    /// closes. Off for that time, the keys reach the menu instead, where the
    /// items carry the same shortcuts.
    func pause() {
        paused = true
        keys = [:]
    }

    func resume() {
        paused = false
        register()
    }

    // MARK: Recording

    func startRecording(_ kind: Kind) {
        stopRecording()
        recording = kind
        problem = nil
        held = []
        keys = [:]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.recording != nil else { return event }
            self.handle(event)
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        held = []
        register()
    }

    private func handle(_ event: NSEvent) {
        guard let kind = recording else { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .flagsChanged {
            held = flags
            return
        }
        if flags.isEmpty && event.keyCode == UInt16(kVK_Escape) {
            problem = nil
            stopRecording()
        } else if flags.isEmpty && [kVK_Delete, kVK_ForwardDelete].contains(Int(event.keyCode)) {
            set(nil, for: kind)
        } else if let shortcut = Shortcut(event: event) {
            set(shortcut, for: kind)
        } else {
            problem = L("Hold ⌘, ⌃ or ⌥ along with the key.")
            NSSound.beep()
        }
    }

    /// Makes it the shortcut, if it can be one: not the other shortcut, and
    /// not taken by another app. Otherwise it says why and keeps recording.
    func set(_ shortcut: Shortcut?, for kind: Kind) {
        if let shortcut {
            let other = kind == .line ? capture : line
            if shortcut == other {
                problem = String(format: L("%@ is already the other shortcut."), shortcut.display)
                NSSound.beep()
                return
            }
            // Registering it for a moment tells whether another app has it.
            // Ours are off while recording, so they do not count.
            keys = [:]
            guard HotKey(shortcut, id: 9, action: {}) != nil else {
                problem = String(format: L("Another app already uses %@."), shortcut.display)
                NSSound.beep()
                register()
                return
            }
        }
        switch kind {
        case .line:
            Shortcut.current = shortcut
            line = shortcut
        case .capture:
            Shortcut.capture = shortcut
            capture = shortcut
        }
        problem = nil
        if recording != nil { stopRecording() } else { register() }
    }
}

// MARK: The field

/// A shortcut drawn as keys. Click it and press new keys to change it; the
/// buttons beside it remove it or bring back the standard one.
struct ShortcutField: View {
    let kind: Shortcuts.Kind
    @ObservedObject private var shortcuts = Shortcuts.shared

    init(_ kind: Shortcuts.Kind) {
        self.kind = kind
    }

    private var isRecording: Bool { shortcuts.recording == kind }
    private var current: Shortcut? { shortcuts.shortcut(for: kind) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    if isRecording { shortcuts.stopRecording() } else { shortcuts.startRecording(kind) }
                } label: {
                    keys
                        .frame(minWidth: 132, minHeight: 30)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isRecording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.14),
                                              lineWidth: isRecording ? 1.5 : 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isRecording ? L("Press the new keys. Esc cancels.") : L("Click to change"))

                Group {
                    if isRecording {
                        IconButton(symbol: "xmark.circle.fill", help: L("Remove Shortcut")) {
                            shortcuts.set(nil, for: kind)
                        }
                        .disabled(current == nil)
                    } else {
                        IconButton(symbol: "arrow.counterclockwise", help: L("Restore Default")) {
                            shortcuts.set(kind.standard, for: kind)
                        }
                        .disabled(current == kind.standard)
                    }
                }
                .frame(width: 20)
            }
            if isRecording, let problem = shortcuts.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isRecording)
        .animation(.easeOut(duration: 0.15), value: shortcuts.problem)
        .onDisappear { if isRecording { shortcuts.stopRecording() } }
    }

    @ViewBuilder private var keys: some View {
        if isRecording {
            if shortcuts.held.isEmpty {
                Text(L("Type the new shortcut"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
            } else {
                KeyCaps(symbols: Shortcut.symbols(of: shortcuts.held) + ["…"])
            }
        } else if let current {
            KeyCaps(symbols: current.symbols)
        } else {
            Text(L("None"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

/// Keys side by side, each on a little keycap.
struct KeyCaps: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, symbol.count > 1 ? 5 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
            }
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .opacity(isEnabled ? 1 : 0)
        .help(help)
    }
}

// MARK: The window

/// Where both shortcuts are changed, from the menu bar.
@MainActor
final class ShortcutsWindow: NSObject, NSWindowDelegate {
    private static var shared: ShortcutsWindow?

    private let window: NSWindow

    static func show() {
        let shown = shared ?? ShortcutsWindow()
        shared = shown
        NSApp.activate(ignoringOtherApps: true)
        shown.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = L("Keyboard Shortcuts")
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let host = NSHostingView(rootView: ShortcutsView())
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        Shortcuts.shared.stopRecording()
        Self.shared = nil
    }

    // Not key any more, so the keys pressed next are not for it.
    func windowDidResignKey(_ notification: Notification) {
        Shortcuts.shared.stopRecording()
    }
}

private struct ShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "command")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Keyboard Shortcuts"))
                        .font(.system(size: 15, weight: .semibold))
                    Text(L("They work from any app."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(Shortcuts.Kind.allCases.enumerated()), id: \.offset) { n, kind in
                    if n > 0 { Divider().padding(.leading, 14) }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.title)
                                .font(.system(size: 13, weight: .medium))
                            Text(kind.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 5)
                        Spacer(minLength: 0)
                        ShortcutField(kind)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

            Text(L("Click a shortcut, then press the new keys with ⌘, ⌃ or ⌥. Esc cancels; Delete removes it."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(width: 480)
    }
}
