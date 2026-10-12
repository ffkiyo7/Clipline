import AppKit
import SwiftUI

/// Clipline's own markup window: rectangles, ellipses, arrows, pen, text,
/// numbered steps and mosaic, with the keys Snipaste users expect. Done
/// writes the marked-up image back over the file and copies it.
@MainActor
final class Editor: NSObject, NSWindowDelegate {
    private static var open: [Editor] = []

    private let url: URL
    private let model: EditorModel
    private let window: NSWindow
    private let canvas: EditorCanvas
    private let onSaved: (URL) -> Void

    /// Opens the file, or brings forward the window already editing it.
    static func edit(_ url: URL, onSaved: @escaping (URL) -> Void) {
        if let existing = open.first(where: { $0.url == url }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        guard let editor = Editor(url: url, onSaved: onSaved) else { NSSound.beep(); return }
        installEditMenu()
        open.append(editor)
        NSApp.activate(ignoringOtherApps: true)
        editor.window.makeKeyAndOrderFront(nil)
        editor.window.makeFirstResponder(editor.canvas)
    }

    private init?(url: URL, onSaved: @escaping (URL) -> Void) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.url = url
        self.onSaved = onSaved
        let points = Pin.naturalSize(ofPixels: CGSize(width: image.width, height: image.height), url: url)
        model = EditorModel(image: image, scale: CGFloat(image.width) / points.width)
        canvas = EditorCanvas(model: model)

        let toolbarHeight: CGFloat = 46
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = min(1, visible.width * 0.85 / (points.width + 24), (visible.height * 0.85 - toolbarHeight) / (points.height + 24))
        let size = NSSize(width: max(640, (points.width + 24) * fit), height: max(320, (points.height + 24) * fit) + toolbarHeight)

        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = url.lastPathComponent
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 640, height: 320)
        window.center()

        let toolbar = NSHostingView(rootView: EditorToolbar(model: model) { [weak self] in self?.run($0) })
        let container = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(canvas)
        container.addSubview(toolbar)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        canvas.onCommand = { [weak self] in self?.run($0) }
    }

    /// A menu bar app has no menus, so text fields would not cut, copy or
    /// paste. An Edit menu, never shown, gives them their keys. Undo is left
    /// out: the canvas handles it.
    static func installEditMenu() {
        guard NSApp.mainMenu == nil else { return }
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())
        main.addItem(item)
        NSApp.mainMenu = main
    }

    // MARK: Commands

    private func run(_ command: EditorCanvas.Command) {
        canvas.commitText()
        switch command {
        case .done:
            if model.hasChanges, let png = renderedPNG() {
                do {
                    try png.write(to: url, options: .atomic)
                    onSaved(url)
                } catch {
                    log.error("Could not save markup: \(error.localizedDescription, privacy: .public)")
                    NSSound.beep()
                    return
                }
            }
            copy(saved: true)
            close()
        case .cancel:
            if model.hasChanges && !confirmDiscard() { return }
            close()
        case .copy:
            copy(saved: !model.hasChanges)
        case .save:
            saveAs()
        case .pin:
            guard let image = model.rendered() else { return }
            Pin.show(url, image: NSImage(cgImage: image, size: Pin.naturalSize(
                ofPixels: CGSize(width: image.width, height: image.height), url: url)))
        }
    }

    private func renderedPNG() -> Data? {
        guard let image = model.rendered() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Copies the image, and the file too once it holds the same picture.
    /// The clipboard watcher is told it was us, so it does not hang a copy.
    private func copy(saved: Bool) {
        guard let png = renderedPNG() else { return }
        let entry = NSPasteboardItem()
        entry.setData(png, forType: .png)
        if saved { entry.setString(url.absoluteString, forType: .fileURL) }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([entry])
        ClipboardWatcher.ownChangeCount = pb.changeCount
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".png"
        panel.allowedContentTypes = [.png]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let target = panel.url, let png = self?.renderedPNG() else { return }
            do { try png.write(to: target, options: .atomic) } catch { NSSound.beep() }
        }
    }

    private func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("Discard your marks?")
        alert.informativeText = L("The screenshot stays as it was.")
        alert.addButton(withTitle: L("Discard"))
        alert.addButton(withTitle: L("Keep Editing"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func close() {
        window.delegate = nil
        window.close()
        Self.open.removeAll { $0 === self }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        run(.cancel)
        return false
    }
}

// MARK: Toolbar

private struct EditorToolbar: View {
    @ObservedObject var model: EditorModel
    let run: (EditorCanvas.Command) -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Room for the window's traffic lights.
            Spacer().frame(width: 62)
            HStack(spacing: 2) {
                ForEach(EditorModel.Tool.allCases, id: \.self) { tool in
                    ToolButton(symbol: tool.symbol, selected: model.tool == tool,
                               help: "\(tool.title)  \(tool.key)") { model.tool = tool }
                }
            }
            Divider().frame(height: 22)
            StyleControls(model: model)
            Spacer(minLength: 8)
            ToolButton(symbol: "arrow.uturn.backward", help: "\(L("Undo"))  ⌘Z") { model.undo() }
                .disabled(!model.canUndo)
            ToolButton(symbol: "arrow.uturn.forward", help: "\(L("Redo"))  ⇧⌘Z") { model.redo() }
                .disabled(!model.canRedo)
            Divider().frame(height: 22)
            ToolButton(symbol: "pin", help: "\(L("Pin to Screen"))  ⌘P") { run(.pin) }
            ToolButton(symbol: "square.and.arrow.down", help: "\(L("Save As…"))  ⌘S") { run(.save) }
            ToolButton(symbol: "doc.on.doc", help: "\(L("Copy"))  ⌘C") { run(.copy) }
            Button(L("Done")) { run(.done) }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("\(L("Done"))  ↩")
                .padding(.trailing, 12)
        }
        .frame(maxHeight: .infinity)
        .background(.bar)
    }
}

/// The colors and the three line widths, shared by the markup window and
/// the screenshot's toolbar.
struct StyleControls: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(EditorModel.colors.indices, id: \.self) { i in
                    Button { model.colorIndex = i } label: {
                        Circle()
                            .fill(Color(nsColor: EditorModel.colors[i]))
                            .frame(width: 15, height: 15)
                            .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 0.5))
                            .padding(2.5)
                            .overlay(Circle().stroke(Color.accentColor, lineWidth: model.colorIndex == i ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                    .help("\(i + 1)")
                }
            }
            Divider().frame(height: 22)
            HStack(spacing: 2) {
                ForEach(EditorModel.widths.indices, id: \.self) { i in
                    ToolButton(selected: model.customWidth == nil && model.widthIndex == i,
                               help: [L("Thin"), L("Medium"), L("Thick")][i]) {
                        model.widthIndex = i
                    } label: {
                        Circle().frame(width: 4 + CGFloat(i) * 3.5, height: 4 + CGFloat(i) * 3.5)
                    }
                }
                // A width scrolled to; clicking it goes back to the preset.
                if let custom = model.customWidth {
                    Button { model.widthIndex = model.widthIndex } label: {
                        HStack(spacing: 3) {
                            Text(String(format: "%g", custom)).monospacedDigit()
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .frame(height: 26)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help(L("Back to the width before scrolling"))
                }
            }
        }
    }
}

struct ToolButton<Label: View>: View {
    var selected = false
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 28, height: 26)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(enabled ? 0.85 : 0.3))
                .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension ToolButton where Label == AnyView {
    init(symbol: String, selected: Bool = false, help: String, action: @escaping () -> Void) {
        self.init(selected: selected, help: help, action: action) {
            AnyView(Image(systemName: symbol).font(.system(size: 13, weight: .medium)))
        }
    }
}
