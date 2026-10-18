import SwiftUI

enum Layout {
    /// How big the photos hang, from Size in the menu bar. The clip, the rope
    /// and the glass frame keep their size; the photos and the room they take
    /// grow or shrink. Medium is the original size.
    enum Size: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: UserDefaults.standard.string(forKey: "lineSize") ?? "") ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lineSize") }
    }

    static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    static var spacing: CGFloat { cardWidth + 24 }
    /// Room below the photos for the source tags and the Copied label.
    static var panelHeight: CGFloat { photoMaxHeight + 118 }
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// Photos hang `spacing` apart, centred. When there are more than the
    /// `visible` that fit: with Keep on line set, they keep their spacing,
    /// the newest stays where the last one would hang on a full line, and
    /// `scroll` brings older ones in from the left. Otherwise (a line hung
    /// on a wider screen) they move closer together so none is past the edge.
    static func x(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat) -> CGFloat {
        if Line.keepOnLine != nil && count > visible {
            let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
            return newest - CGFloat(count - 1 - index) * spacing + scroll
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(spacing, max(0, width - 200) / gaps) : spacing
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Rope(width: width)

                // The pointer on the rope: the rope lights up where it can be cut.
                if line.scissorsX != nil && line.stroke == nil {
                    Rope.path(width: width)
                        .stroke(Color.white.opacity(0.45), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .blur(radius: 2)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
                if let stroke = line.stroke {
                    CutTrail(stroke: stroke, width: width)
                }

                if line.items.isEmpty && !line.noteClip {
                    Hint(carrying: line.carrying)
                        .position(x: width / 2, y: Layout.ropeY(x: width / 2, width: width) + 34)
                        .transition(.opacity)
                }

                // The note clip takes the next place after the newest photo.
                if line.noteClip {
                    let place = line.place(line.items.count)
                    let x = Layout.x(index: place.index, count: place.count, width: width,
                                     visible: line.visibleCount, scroll: line.scroll)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    NoteClip(notes: .shared, line: line)
                        .opacity(min(1, max(0, min(x, width - x) / 90)))
                        .position(x: x, y: ropeY - Layout.pinAbove + NoteClip.height / 2)
                        .transition(.opacity)
                }

                ForEach(Array(line.items.enumerated()), id: \.element.id) { index, item in
                    let place = line.place(index)
                    let x = Layout.x(index: place.index, count: place.count, width: width,
                                     visible: line.visibleCount, scroll: line.scroll)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line)
                        .zIndex(line.hoveredID == item.id ? 1 : 0)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        // Photos scrolled towards an edge fade out before they reach it.
                        .opacity(min(1, max(0, min(x, width - x) / 90)))
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }

                ForEach(line.snips) { snip in
                    SnipSpark()
                        .position(x: snip.x, y: Layout.ropeY(x: snip.x, width: width))
                }

                if let x = line.scissorsX {
                    let ropeY = Layout.ropeY(x: x, width: width)
                    // The blades' tips sit at the pointer, the handles trail behind.
                    Scissors()
                        .scaleEffect(x: line.scissorsFaceLeft ? -1 : 1)
                        .position(x: x + (line.scissorsFaceLeft ? 12 : -12), y: ropeY)
                    if line.stroke == nil && Line.cutsMade < 2 {
                        CutHint()
                            .fixedSize()
                            .position(x: x, y: ropeY + 30)
                            .transition(.opacity)
                    }
                }

                if let cut = line.lastCut, line.stroke == nil {
                    UndoPill(cut: cut, line: line)
                        .id(cut.id)
                        .fixedSize()
                        .position(x: min(max(cut.x, 130), width - 130), y: Layout.panelHeight - 26)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: line.items.map(\.id))
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: line.gap)
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            .animation(.easeInOut(duration: 0.3), value: line.noteClip)
            .animation(.easeOut(duration: 0.15), value: line.scissorsX == nil)
            .animation(.easeOut(duration: 0.2), value: line.lastCut?.id)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.28, dampingFraction: 0.85)
                                     : .easeIn(duration: 0.14), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
        .onPreferenceChange(TagRectsKey.self) { rects in
            line.tagRects = rects
        }
        .onPreferenceChange(ClipRectKey.self) { rect in
            line.clipRect = rect
        }
        .onPreferenceChange(UndoRectKey.self) { rect in
            line.undoRect = rect
        }
    }
}

private struct Hint: View {
    let carrying: Bool

    var body: some View {
        Text(carrying ? L("Drop it here to hang it") : L("Take a screenshot and it will hang here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    static func path(width: CGFloat) -> Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        let path = Self.path(width: width)
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.06),
                .init(color: .black, location: 0.94),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

// MARK: The scissors

/// The colour of a fresh cut.
private let cutTint = Color(red: 1, green: 0.62, blue: 0.26)

/// Scissors lying along the rope, blades forward. Drawn here rather than as
/// the cursor: an app in the background cannot change the cursor.
private struct Scissors: View {
    private var shape: Path {
        Path { p in
            p.addEllipse(in: CGRect(x: 2.4, y: 2.4, width: 7.2, height: 7.2))
            p.addEllipse(in: CGRect(x: 2.4, y: 12.4, width: 7.2, height: 7.2))
            p.move(to: CGPoint(x: 9.2, y: 7.6))
            p.addLine(to: CGPoint(x: 27, y: 14.6))
            p.move(to: CGPoint(x: 9.2, y: 14.4))
            p.addLine(to: CGPoint(x: 27, y: 7.4))
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shape.stroke(Color.white, style: StrokeStyle(lineWidth: 3.6, lineCap: .round))
            shape.stroke(Color(white: 0.12), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            Circle().fill(Color(white: 0.12)).frame(width: 2.6, height: 2.6).offset(x: 14.2, y: 9.7)
        }
        .frame(width: 30, height: 22, alignment: .topLeading)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        .allowsHitTesting(false)
    }
}

/// The stretch of rope cut so far, brightest at the scissors and fading
/// behind them.
private struct CutTrail: View {
    let stroke: Stroke
    let width: CGFloat

    private static let step: CGFloat = 6
    private static let length: CGFloat = 260

    /// Short pieces along the rope, each as bright as it is near the scissors.
    private var pieces: [(id: Int, path: Path, opacity: Double)] {
        let from = stroke.from, to = stroke.to
        let span = abs(to - from)
        let count = Int((min(span, Self.length) / Self.step).rounded(.up))
        let direction: CGFloat = to >= from ? 1 : -1
        return (0..<count).map { n in
            let a = to - direction * CGFloat(n) * Self.step
            let b = to - direction * min(span, CGFloat(n + 1) * Self.step)
            let path = Path { p in
                p.move(to: CGPoint(x: a, y: Layout.ropeY(x: a, width: width)))
                p.addLine(to: CGPoint(x: b, y: Layout.ropeY(x: b, width: width)))
            }
            return (id: n, path: path, opacity: Double(1 - CGFloat(n) * Self.step / Self.length))
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(pieces, id: \.id) { piece in
                piece.path
                    .stroke(Color.white.opacity(0.55 * piece.opacity), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .blur(radius: 1.5)
                piece.path
                    .stroke(cutTint.opacity(piece.opacity), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

/// A little burst where a clip snapped.
private struct SnipSpark: View {
    @State private var out = false

    var body: some View {
        ZStack {
            ForEach([-70.0, -25, 20, 65, 150, 210], id: \.self) { angle in
                Capsule()
                    .fill(cutTint)
                    .frame(width: 1.4, height: 5)
                    .offset(y: out ? -12 : -4)
                    .rotationEffect(.degrees(angle))
            }
        }
        .frame(width: 30, height: 30)
        .opacity(out ? 0 : 1)
        .onAppear { withAnimation(.easeOut(duration: 0.35)) { out = true } }
        .allowsHitTesting(false)
    }
}

/// Said the first few times the scissors show.
private struct CutHint: View {
    var body: some View {
        Text(L("Hold and sweep along the line to cut photos down"))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .glassFrame(capsule: true)
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            .allowsHitTesting(false)
    }
}

/// After a cut: how many came down, and a moment to put them back.
private struct UndoPill: View {
    let cut: Cut
    @ObservedObject var line: Line
    @State private var left: CGFloat = 1

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors")
                .font(.system(size: 11, weight: .semibold))
            Text(String(format: L("%d taken down"), cut.taken.count))
                .font(.system(size: 12, weight: .medium))
            Rectangle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 0.5, height: 16)
            Text(L("Undo"))
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .overlay(ClickArea { _ in line.undoCut() })
        }
        .foregroundStyle(.primary)
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .frame(height: 36)
        .overlay(alignment: .bottomLeading) {
            // The time left to undo.
            GeometryReader { g in
                Capsule()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: max(0, g.size.width * left), height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 16)
            .padding(.bottom, 3)
        }
        .glassFrame(capsule: true)
        .shadow(color: .black.opacity(0.2), radius: 11, y: 6)
        .background(
            GeometryReader { g in
                Color.clear.preference(key: UndoRectKey.self, value: g.frame(in: .global))
            }
        )
        .onAppear { withAnimation(.linear(duration: Line.undoDelay)) { left = 0 } }
    }
}

struct UndoRectKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct ClipRectKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

struct TagRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
