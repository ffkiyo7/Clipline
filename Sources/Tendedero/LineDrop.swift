import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The line's view, which also takes what is dropped on it: image files from
/// Finder or any file manager, files an app promises, like Photos, and plain
/// image data, like a picture dragged out of a browser.
///
/// Files hang where they are, and only leave the line when taken down, like
/// screenshots on the Desktop. Images without a file are saved in
/// Tendedero's folder first.
final class LineHost: NSHostingView<LineView> {
    /// Hangs what was dropped, in order.
    var onDrop: ([URL]) -> Void = { _ in }

    required init(rootView: LineView) {
        super.init(rootView: rootView)
        registerForDraggedTypes(Self.types)
    }

    @MainActor required init?(coder: NSCoder) { fatalError() }

    static let types: [NSPasteboard.PasteboardType] =
        [.fileURL, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { .init($0) }

    // MARK: What can hang

    /// Image files and screen recordings, the things the line can show.
    static func canHang(_ url: URL) -> Bool {
        if isRecording(url) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private static func files(on pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(canHang)
    }

    private static func promises(on pb: NSPasteboard) -> [NSFilePromiseReceiver] {
        let all = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        return all.filter { receiver in
            receiver.fileTypes.contains { UTType($0)?.conforms(to: .image) == true }
        }
    }

    /// Whether a drag carries something that can hang on the line.
    static func canHang(_ pb: NSPasteboard) -> Bool {
        guard let types = pb.types, !Set(types).isDisjoint(with: Self.types) else { return false }
        return !files(on: pb).isEmpty || !promises(on: pb).isEmpty
            || (!types.contains(.fileURL) && NSImage.canInit(with: pb))
    }

    // MARK: NSDraggingDestination

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        // A photo dragged off the line itself is not dropped back on it.
        if sender.draggingSource is GrabView { return [] }
        return Self.canHang(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        log.notice("Drag over the line with \((pb.types ?? []).map(\.rawValue).joined(separator: ", "), privacy: .public)")
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !operation(for: sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let files = Self.files(on: pb)
        if !files.isEmpty {
            onDrop(files)
            return true
        }
        let promises = Self.promises(on: pb)
        if !promises.isEmpty {
            receive(promises)
            return true
        }
        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        do {
            onDrop([try Inbox.keep(png, prefix: "Image")])
            return true
        } catch {
            log.error("Could not save a dropped image: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Promised files arrive in Tendedero's folder, each when it is written.
    private func receive(_ promises: [NSFilePromiseReceiver]) {
        try? FileManager.default.createDirectory(at: Inbox.folder, withIntermediateDirectories: true)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for promise in promises {
            promise.receivePromisedFiles(atDestination: Inbox.folder, options: [:], operationQueue: queue) { url, error in
                DispatchQueue.main.async { [weak self] in
                    if let error {
                        log.error("Could not receive a dropped file: \(error.localizedDescription, privacy: .public)")
                    } else if Self.canHang(url) {
                        self?.onDrop([url])
                    }
                }
            }
        }
    }
}
