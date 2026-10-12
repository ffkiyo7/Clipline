import AppKit
import Combine

/// The text you copy, newest first. Copying the same text again moves it
/// back to the top instead of keeping it twice. Kept in a file only you can
/// read, in Clipline's own folder.
@MainActor
final class Notes: ObservableObject {
    static let shared = Notes()

    @Published private(set) var all: [Note] = []

    /// How many unpinned notes are kept.
    static let limit = 200
    /// Anything longer is not a note.
    private static let maxLength = 200_000

    /// On out of the box: the clip is how copied text is found again.
    static var isEnabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "notesOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "notesOff") }
    }

    private static let file: URL = Inbox.folder.deletingLastPathComponent()
        .appendingPathComponent("Clipboard.json")

    private let saver: FileSaver

    private init() {
        // What people copy can be private: only they can read it.
        saver = FileSaver(url: Self.file, permissions: 0o600) { error in
            log.error("Could not save copied text: \(error.localizedDescription, privacy: .public)")
        }
        all = NoteList.read(from: Self.file) { message in
            log.error("\(message, privacy: .public)")
        }
    }

    /// Pinned first, then newest first.
    var sorted: [Note] { NoteList.sorted(all) }

    func add(_ text: String, source: Source?) {
        var notes = all
        guard NoteList.add(text, source: source, to: &notes, limit: Self.limit, maxLength: Self.maxLength) else { return }
        all = notes
        save()
    }

    /// Copies a note, and it moves to the top as if just copied. The
    /// clipboard watcher is told it was us.
    func copy(_ id: UUID) {
        var notes = all
        guard let note = NoteList.bump(id, in: &notes) else { return }
        all = notes
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(note.text, forType: .string)
        ClipboardWatcher.ownChangeCount = pb.changeCount
        save()
    }

    func togglePin(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].pinned.toggle()
        save()
    }

    func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
        save()
    }

    /// Clears everything but the pinned notes.
    func clear() {
        all.removeAll { !$0.pinned }
        save()
    }

    /// Writes what is still waiting, before the app quits.
    func flush() {
        saver.flush()
    }

    // MARK: File

    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        saver.save(data)
    }
}
