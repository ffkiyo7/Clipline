import AppKit
import SwiftUI

/// A clip at the end of the line holding a little stack of glass notes: the text
/// you copied. Copying never brings the line down; the stack just grows.
/// Click it to see every note and search them.
struct NoteClip: View {
    @ObservedObject var notes: Notes
    @ObservedObject var line: Line
    @State private var hovering = false

    static let paper = CGSize(width: 70, height: 56)
    /// Where the notes start below the top, as the photos' cards do.
    static let paperTop: CGFloat = 14
    static let height: CGFloat = paperTop + paper.height + 10
    /// The paperclip sits near the right corner and hangs the stack from
    /// the line, so everything swings from there.
    private static let clipAnchor = UnitPoint(x: 0.8, y: 0)

    private var top: String {
        notes.sorted.first.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ZStack {
                sheet.rotationEffect(.degrees(6), anchor: Self.clipAnchor).opacity(notes.all.count > 2 ? 1 : 0)
                sheet.rotationEffect(.degrees(-4), anchor: Self.clipAnchor).opacity(notes.all.count > 1 ? 1 : 0)
                sheet.overlay(alignment: .topLeading) {
                    Text(top)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .padding(.leading, 7)
                        .padding(.trailing, 20)
                        .padding(.top, 8)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(notes.all.count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
            }
            .frame(width: Self.paper.width, height: Self.paper.height)
            .offset(y: Self.paperTop)
            Paperclip()
                .offset(x: Self.paper.width * Self.clipAnchor.x - Paperclip.size.width / 2, y: 1)
        }
        .frame(width: Self.paper.width, height: Self.height, alignment: .topLeading)
        .rotationEffect(.degrees(-2), anchor: Self.clipAnchor)
        .scaleEffect(hovering ? 1.05 : 1, anchor: Self.clipAnchor)
        .shadow(color: .black.opacity(hovering ? 0.24 : 0.16), radius: hovering ? 8 : 5, y: hovering ? 5 : 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
        .overlay(ClickArea { rect in line.onOpenNotes?(rect) })
        .onHover { hovering = $0 }
        .help(L("Copied text"))
        .background(
            GeometryReader { g in
                Color.clear.preference(key: ClipRectKey.self, value: g.frame(in: .global))
            }
        )
    }

    private var sheet: some View {
        // The same glass as the photos' frames.
        Color.clear
            .frame(width: Self.paper.width, height: Self.paper.height)
            .glassFrame(cornerRadius: 10, materialOpacity: 0.55)
    }
}

/// A silver paperclip: its top loop hangs on the line, the rest holds the
/// corner of the notes.
struct Paperclip: View {
    static let size = CGSize(width: 11, height: 32)

    private let steel = LinearGradient(colors: [Color(white: 0.97), Color(white: 0.6)],
                                       startPoint: .leading, endPoint: .trailing)

    var body: some View {
        Path { p in
            // Legs, left to right: outer, inner, inner, outer.
            let a: CGFloat = 1.2, b: CGFloat = 3.9, c: CGFloat = 7.1, d: CGFloat = 9.8
            func bend(from x1: CGFloat, to x2: CGFloat, at y: CGFloat, down: Bool) {
                let r = abs(x2 - x1) / 2, tip = down ? y + r : y - r
                p.addQuadCurve(to: CGPoint(x: (x1 + x2) / 2, y: tip), control: CGPoint(x: x1, y: tip))
                p.addQuadCurve(to: CGPoint(x: x2, y: y), control: CGPoint(x: x2, y: tip))
            }
            p.move(to: CGPoint(x: b, y: 13))
            p.addLine(to: CGPoint(x: b, y: 26))
            bend(from: b, to: c, at: 26, down: true)
            p.addLine(to: CGPoint(x: c, y: 4.6))
            bend(from: c, to: a, at: 4.6, down: false)
            p.addLine(to: CGPoint(x: a, y: 27.5))
            bend(from: a, to: d, at: 27.5, down: true)
            p.addLine(to: CGPoint(x: d, y: 9))
        }
        .stroke(steel, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        .frame(width: Self.size.width, height: Self.size.height)
        .scaleEffect(0.85, anchor: .top)
        .shadow(color: .black.opacity(0.35), radius: 1, y: 0.8)
        .allowsHitTesting(false)
    }
}

/// Clicks reach a view on a panel that never becomes key only through
/// AppKit, the way the photos take theirs.
private struct ClickArea: NSViewRepresentable {
    let onClick: (NSRect) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: ((NSRect) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseUp(with event: NSEvent) {
            guard let window, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            onClick?(window.convertToScreen(convert(bounds, to: nil)))
        }

        override func mouseDown(with event: NSEvent) {}
    }
}
