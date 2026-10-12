import Foundation

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

/// The rules the note clip keeps, apart from the clipboard and the file so
/// they can be tested: newest first, copying the same text again moves it
/// back to the top, and only so many unpinned notes are kept.
enum NoteList {
    /// Pinned first, then newest first.
    static func sorted(_ notes: [Note]) -> [Note] {
        notes.filter(\.pinned) + notes.filter { !$0.pinned }
    }

    /// False when the text is not a note: blank, or too long.
    @discardableResult
    static func add(_ text: String, source: Source?, date: Date = Date(),
                    to notes: inout [Note], limit: Int, maxLength: Int) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= maxLength else { return false }
        var note = Note(text: text, date: date, source: source)
        if let i = notes.firstIndex(where: { $0.text == text }) {
            note.id = notes[i].id
            note.pinned = notes[i].pinned
            notes.remove(at: i)
        }
        notes.insert(note, at: 0)
        trim(&notes, limit: limit)
        return true
    }

    /// Moves a note to the top as if just copied, and returns it.
    @discardableResult
    static func bump(_ id: UUID, date: Date = Date(), in notes: inout [Note]) -> Note? {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return nil }
        var note = notes.remove(at: i)
        note.date = date
        notes.insert(note, at: 0)
        return note
    }

    /// Keeps every pinned note and the newest `limit` unpinned ones.
    static func trim(_ notes: inout [Note], limit: Int) {
        var unpinned = 0
        notes.removeAll { note in
            guard !note.pinned else { return false }
            unpinned += 1
            return unpinned > limit
        }
    }

    // MARK: File

    /// The notes saved in a file. A file that cannot be read as notes is
    /// moved aside first, so the next save does not overwrite what may still
    /// be recovered from it.
    static func read(from url: URL, onError: (String) -> Void = { _ in }) -> [Note] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try JSONDecoder().decode([Note].self, from: data)
        } catch {
            let aside = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))")
                .appendingPathExtension(url.pathExtension)
            do {
                try FileManager.default.moveItem(at: url, to: aside)
                onError("Could not read \(url.lastPathComponent), moved it to \(aside.lastPathComponent): \(error)")
            } catch let moveError {
                onError("Could not read \(url.lastPathComponent) or move it aside: \(moveError)")
            }
            return []
        }
    }
}
