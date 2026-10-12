import SwiftUI

/// One photo with its clothespin. All the charm lives here: it drops onto
/// the line, swings, sways with the breeze and falls when you pull it off.
struct PeggedView: View {
    let item: Pegged
    @ObservedObject var line: Line

    @State private var swing: Double = 0
    @State private var arrived = false
    @State private var hoveringCard = false
    @State private var hoveringTag = false
    /// The pointer over the photo or its tag: the tag counts as part of it,
    /// so moving down onto the tag does not close it again.
    private var hovering: Bool { hoveringCard || hoveringTag }

    private var copied: Bool { line.copiedID == item.id }
    private var dragging: Bool { line.draggingID == item.id }
    private var pressed: Bool { line.pressedID == item.id }
    private var showsTag: Bool { item.source != nil && line.tagStyle != .hidden }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin()
                .zIndex(1)
            VStack(spacing: 0) {
                card
                tag
            }
        }
        .rotationEffect(.degrees(swing + item.tilt), anchor: .top)
        .offset(y: arrived ? 0 : -46)
        // The fall itself is drawn over the whole screen by CaptureFlight, so
        // the card here just steps aside at once.
        .opacity(item.falling || item.flying ? 0 : (arrived ? 1 : 0))
        .transaction { t in if item.falling { t.animation = nil } }
        .animation(.easeOut(duration: 0.16), value: item.flying)
        .onAppear(perform: arrive)
        .onChange(of: item.flying) { was, now in if was && !now { land() } }
        .onChange(of: line.gust) { _, _ in breeze() }
        .onChange(of: copied) { _, isCopied in if isCopied { nudge(3) } }
    }

    /// The photo fits inside the card area keeping its proportions, so the
    /// white border hugs it whether the screenshot is wide or tall.
    static func photoSize(for size: CGSize) -> CGSize {
        let maxW = Layout.cardWidth - 14, maxH = Layout.photoMaxHeight
        guard size.width > 0, size.height > 0 else { return CGSize(width: maxW, height: maxH) }
        let scale = min(maxW / size.width, maxH / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// The card around the photo: the photo plus the glass inset.
    static func cardSize(for size: CGSize) -> CGSize {
        let p = photoSize(for: size)
        return CGSize(width: p.width + Frame.inset * 2, height: p.height + Frame.inset * 2)
    }

    /// Distance from the top of the hanging view (the clip) to the card.
    static let cardOffsetBelowTop: CGFloat = 26 - 12

    private var photoSize: CGSize { Self.photoSize(for: item.thumb.size) }

    private var card: some View {
        Image(nsImage: item.thumb)
            .resizable()
            .interpolation(.high)
            .frame(width: photoSize.width, height: photoSize.height)
            // How the end-to-end tests find the photo.
            .accessibilityIdentifier("clipline.photo." + item.url.lastPathComponent)
            // Concentric corners: the photo's radius is the frame's minus the
            // inset, the way macOS rounds nested shapes.
            .clipShape(RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Frame.radius - Frame.inset, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay {
                // A recording says so with a play button over its first frame.
                if item.isRecording {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)
                        .glassFrame(circle: true)
                        .allowsHitTesting(false)
                }
            }
            .padding(Frame.inset)
            .glassFrame(cornerRadius: Frame.radius)
            .shadow(color: .black.opacity(hovering ? 0.26 : 0.18), radius: hovering ? 14 : 10, y: hovering ? 8 : 5)
            // Holding presses the photo in slowly, so a long press feels like
            // it is building up to something.
            .scaleEffect(pressed ? 0.95 : (hovering ? 1.035 : 1), anchor: .top)
            .animation(pressed ? .easeInOut(duration: 0.45) : .spring(response: 0.3, dampingFraction: 0.6), value: pressed)
            .opacity(dragging ? 0.45 : 1)
            .overlay(alignment: .topLeading) {
                // Drawn here, clicked through GrabView, which sits on top. A
                // cross sends a file in Clipline's folder to the Trash; for a
                // file anywhere else it only hides it from the line.
                Image(systemName: line.isInInbox(item.id) ? "xmark" : "eye.slash")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 20, height: 20)
                    .glassFrame(circle: true)
                    .padding(3)
                    .opacity(hovering && !dragging ? 1 : 0)
                    .scaleEffect(hovering ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay(GrabArea(item: item, line: line))
            .overlay(alignment: .bottom) {
                // With a tag, the tag itself says Copied.
                if copied && !showsTag {
                    Label(L("Copied"), systemImage: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassFrame(capsule: true)
                        .offset(y: 16)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                }
            }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.2), value: copied)
            .onHover { inside in
                hoveringCard = inside
                updateHovered()
            }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: HitRectsKey.self,
                                           value: item.falling ? [:] : [item.id: g.frame(in: .global)])
                }
            )
    }

    /// Where the tag's thread is tied along the bottom of the card: a little
    /// right of the middle, whatever the photo's shape.
    static let tagAnchor: CGFloat = 0.62

    /// The tag hangs on its thread from a fixed point under the card, centred
    /// on that thread, so wide and narrow photos wear it alike.
    @ViewBuilder private var tag: some View {
        if let source = item.source, showsTag {
            let width = Self.cardSize(for: item.thumb.size).width
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: width, height: 1)
                SourceTag(source: source, style: line.tagStyle,
                          expanded: hovering && !dragging, copied: copied,
                          id: item.id, falling: item.falling) { inside in
                    hoveringTag = inside
                    updateHovered()
                }
                .alignmentGuide(.leading) { $0[HorizontalAlignment.center] - width * Self.tagAnchor }
                .opacity(dragging ? 0.45 : 1)
            }
            .frame(width: width, height: 1, alignment: .topLeading)
            .zIndex(-1)
        }
    }

    private func updateHovered() {
        if hovering { line.hoveredID = item.id } else if line.hoveredID == item.id { line.hoveredID = nil }
    }

    private func arrive() {
        // A capture that flew in is already in place; the flight did the arriving.
        if item.flying {
            arrived = true
            return
        }
        swing = 16
        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { arrived = true }
        withAnimation(.interpolatingSpring(stiffness: 46, damping: 2.6)) { swing = 0 }
    }

    /// Landing after the flight: no jump, just a small sway from rest.
    private func land() {
        nudge(2.2)
    }

    private func breeze() {
        let delay = Double.random(in: 0...0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            nudge(Double.random(in: 1.6...3.4))
        }
    }

    private func nudge(_ degrees: Double) {
        withAnimation(.easeOut(duration: 0.3)) { swing = degrees }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.interpolatingSpring(stiffness: 38, damping: 2.4)) { swing = 0 }
        }
    }
}

/// A small tag tied below the photo's corner on a thread, naming the app the
/// capture came from. Resting, it shows the icon (and the name, if chosen);
/// under the pointer it opens up to the window title too.
struct SourceTag: View {
    let source: Source
    let style: Source.TagStyle
    let expanded: Bool
    let copied: Bool
    let id: UUID
    let falling: Bool
    let onHover: (Bool) -> Void

    private var showsName: Bool { style == .name || expanded || copied }
    private var title: String? { expanded && !copied ? source.windowTitle : nil }
    private var name: String { copied ? L("Copied") : source.appName }

    private static let nameFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    private static let titleFont = NSFont.systemFont(ofSize: 10)

    /// The text's own width, up to what fits under the photo: the tag hugs
    /// short names and only long ones are cut short.
    private var textWidth: CGFloat {
        func measure(_ s: String, _ font: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        let natural = max(measure(name, Self.nameFont), title.map { measure($0, Self.titleFont) } ?? 0)
        let room = Layout.cardWidth - 20 - 3 - 14 - 5 - 7
        return min(room, natural.rounded(.up) + 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(white: 0.55))
                .frame(width: 0.75, height: 9)
            HStack(alignment: title == nil ? .center : .top, spacing: 5) {
                if copied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                } else if let icon = source.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 10)).frame(width: 14, height: 14)
                }
                if showsName {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(Font(Self.nameFont))
                        if let title {
                            Text(title)
                                .font(Font(Self.titleFont))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: textWidth, alignment: .leading)
                }
            }
            .foregroundStyle(.primary)
            .padding(.leading, 3)
            .padding(.trailing, showsName ? 7 : 3)
            .padding(.vertical, 3)
            .glassFrame(cornerRadius: 6)
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1.5)
        }
        // It hangs a little crooked from its thread.
        .rotationEffect(.degrees(-4), anchor: .top)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: expanded)
        // The panel lets clicks through except over photos and their tags.
        .background(
            GeometryReader { g in
                Color.clear.preference(key: TagRectsKey.self, value: falling ? [:] : [id: g.frame(in: .global)])
            }
        )
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}

enum Frame {
    static let radius: CGFloat = 16
    static let inset: CGFloat = 4
}

extension View {
    /// A crisp glass: the system's blurred material with a thin specular
    /// edge, lit from above. No refraction, so the background stays sharp
    /// around the frame instead of bending like gel.
    /// `materialOpacity` below 1 lets more of what is behind show through.
    func glassFrame(cornerRadius: CGFloat = 0, circle: Bool = false, capsule: Bool = false,
                    materialOpacity: Double = 1) -> some View {
        let shape: AnyShape = circle ? AnyShape(Circle())
            : capsule ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        return background(shape.fill(.ultraThinMaterial).opacity(materialOpacity))
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.12)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .overlay(shape.stroke(Color.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
    }
}

/// A minimal aluminium clip: a brushed metal pill with a slot where it
/// grips the line, and a soft shadow so it reads on any background.
struct Clothespin: View {
    private let metal = LinearGradient(
        stops: [
            .init(color: Color(white: 0.70), location: 0),
            .init(color: Color(white: 0.93), location: 0.35),
            .init(color: Color(white: 0.82), location: 0.65),
            .init(color: Color(white: 0.62), location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(metal)
            .frame(width: 9, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .stroke(LinearGradient(colors: [Color.white.opacity(0.9), Color.black.opacity(0.18)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.6)
            )
            .overlay(alignment: .top) {
                // The slot the line passes through.
                Capsule()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 5, height: 1.4)
                    .padding(.top, 8.5)
            }
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1.5)
            .allowsHitTesting(false)
    }
}
