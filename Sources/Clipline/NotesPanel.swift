import AppKit
import SwiftUI

/// The note clip opened up: every piece of text you copied, newest first,
/// with a search field. It takes the keyboard without activating Clipline,
/// so the app you were in stays in front and ⌘V pastes there.
@MainActor
final class NotesPanel: NSPanel, NSWindowDelegate {
    private static var shared: NotesPanel?

    static var isOpen: Bool { shared?.isVisible ?? false }

    /// Opens below the clip, or closes it if it is already open.
    static func toggle(below anchor: NSRect) {
        if isOpen { close(); return }
        let panel = shared ?? NotesPanel()
        shared = panel
        panel.show(below: anchor)
    }

    static func close() {
        shared?.orderOut(nil)
    }

    private let state = NotesPanelState()
    private static let size = NSSize(width: 340, height: 440)

    private init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        delegate = self

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .popover
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        let host = NSHostingView(rootView: NotesList(notes: .shared, state: state) { NotesPanel.close() })
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    private func show(below anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var origin = NSPoint(x: anchor.midX - Self.size.width / 2, y: anchor.minY - 8 - Self.size.height)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - 8 - Self.size.width)
            origin.y = max(origin.y, visible.minY + 8)
        }
        setFrameOrigin(origin)
        state.query = ""
        state.selection = 0
        makeKeyAndOrderFront(nil)
        // The caret goes to the search field once the panel is key. Asked
        // before, as when another app was in front, it landed nowhere and
        // the arrow keys and Return did nothing until a click.
        DispatchQueue.main.async { self.state.focus += 1 }
    }

    /// Clicking anywhere else puts it away.
    func windowDidResignKey(_ notification: Notification) {
        orderOut(nil)
    }
}

@MainActor
final class NotesPanelState: ObservableObject {
    @Published var query = ""
    @Published var selection = 0
    /// Bumped each time the panel opens, to put the caret in the search field.
    @Published var focus = 0
    @Published var copiedID: UUID?
}

private struct NotesList: View {
    @ObservedObject var notes: Notes
    @ObservedObject var state: NotesPanelState
    let dismiss: () -> Void
    @FocusState private var searchFocused: Bool

    private var results: [Note] {
        let query = state.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notes.sorted }
        return notes.sorted.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || ($0.source?.appName.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        let results = results
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("Search copied text"), text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                    .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                    .onKeyPress(.return) {
                        if results.indices.contains(state.selection) { copy(results[state.selection]) }
                        return .handled
                    }
                    .onKeyPress(.escape) { dismiss(); return .handled }
                    .onChange(of: state.query) { _, _ in state.selection = 0 }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(10)

            Divider()

            if results.isEmpty {
                Spacer()
                Text(notes.all.isEmpty ? L("Text you copy shows up here") : L("No matches"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, note in
                                NoteRow(note: note, selected: index == state.selection,
                                        copied: state.copiedID == note.id)
                                    .id(note.id)
                                    .onTapGesture { copy(note) }
                                    .onHover { if $0 { state.selection = index } }
                                    .contextMenu {
                                        Button(L("Copy")) { copy(note) }
                                        Button(note.pinned ? L("Unpin") : L("Keep at Top")) { notes.togglePin(note.id) }
                                        Divider()
                                        Button(L("Delete")) { notes.delete(note.id) }
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: state.selection) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id)
                    }
                }
            }

            Divider()
            HStack {
                Text(String(format: L("%d items"), notes.all.count))
                Spacer()
                Button(L("Clear")) { clear() }
                    .buttonStyle(.plain)
                    .disabled(notes.all.allSatisfy(\.pinned))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .onAppear { searchFocused = true }
        .onChange(of: state.focus) { _, _ in searchFocused = true }
    }

    private func move(_ step: Int, in results: [Note]) {
        guard !results.isEmpty else { return }
        state.selection = min(results.count - 1, max(0, state.selection + step))
    }

    /// Copies, shows it for a moment, and gets out of the way for ⌘V.
    private func copy(_ note: Note) {
        notes.copy(note.id)
        state.copiedID = note.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            state.copiedID = nil
            dismiss()
        }
    }

    private func clear() {
        let alert = NSAlert()
        alert.messageText = L("Clear copied text?")
        alert.informativeText = L("Notes kept at the top stay.")
        alert.addButton(withTitle: L("Clear"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { notes.clear() }
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool
    let copied: Bool

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let icon = note.source?.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(preview)
                    .font(.system(size: 12.5))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8))
                    }
                    if copied {
                        Label(L("Copied"), systemImage: "checkmark")
                    } else {
                        Text([note.source?.appName, Self.relative.localizedString(for: note.date, relativeTo: Date())]
                            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }

    /// Leading blank lines and indentation say nothing in a preview.
    private var preview: String {
        String(note.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
    }
}
