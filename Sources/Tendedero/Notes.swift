import AppKit
import Combine

/// One piece of copied text, kept in the note clip at the end of the line.
struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var date: Date
    /// The app it was copied from, when known.
    var source: Source?
    /// Pinned notes stay at the top and are never trimmed.
    var pinned = false
}

/// The text you copy, newest first. Copying the same text again moves it
/// back to the top instead of keeping it twice. Kept in a file only you can
/// read, in Tendedero's own folder.
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

    private init() {
        load()
    }

    /// Pinned first, then newest first.
    var sorted: [Note] {
        all.filter(\.pinned) + all.filter { !$0.pinned }
    }

    func add(_ text: String, source: Source?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= Self.maxLength else { return }
        var note = Note(text: text, date: Date(), source: source)
        if let i = all.firstIndex(where: { $0.text == text }) {
            note.id = all[i].id
            note.pinned = all[i].pinned
            all.remove(at: i)
        }
        all.insert(note, at: 0)
        trim()
        save()
    }

    /// Copies a note, and it moves to the top as if just copied. The
    /// clipboard watcher is told it was us.
    func copy(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(all[i].text, forType: .string)
        ClipboardWatcher.ownChangeCount = pb.changeCount
        var note = all.remove(at: i)
        note.date = Date()
        all.insert(note, at: 0)
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

    private func trim() {
        var unpinned = 0
        all.removeAll { note in
            guard !note.pinned else { return false }
            unpinned += 1
            return unpinned > Self.limit
        }
    }

    // MARK: File

    private func load() {
        guard let data = try? Data(contentsOf: Self.file) else { return }
        all = (try? JSONDecoder().decode([Note].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        let url = Self.file
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                // What people copy can be private: only they can read it.
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                log.error("Could not save copied text: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
