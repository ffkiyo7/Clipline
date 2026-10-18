import AppKit
import SwiftUI

/// The welcome shown on first launch, and again from the menu bar: a few
/// short scenes, each acting out one thing Clipline does on a little
/// desktop. Continue goes to the next, Skip straight to the last, where
/// Clipline asks whether to handle your screenshots.
@MainActor
final class Welcome: NSObject, NSWindowDelegate {
    private static var shared: Welcome?

    static var isOpen: Bool { shared != nil }

    private let window: NSWindow
    private let onClose: () -> Void

    /// `setInbox` turns screenshot handling on or off from the last step.
    /// `onClose` runs once the window has gone, however it was closed.
    static func show(setInbox: @escaping (Bool) -> Void, onClose: @escaping () -> Void = {}) {
        if let shared {
            NSApp.activate(ignoringOtherApps: true)
            shared.window.makeKeyAndOrderFront(nil)
            return
        }
        let welcome = Welcome(setInbox: setInbox, onClose: onClose)
        shared = welcome
        NSApp.activate(ignoringOtherApps: true)
        welcome.window.makeKeyAndOrderFront(nil)
    }

    private init(setInbox: @escaping (Bool) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(origin: .zero, size: WelcomeView.size),
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = L("Welcome to Clipline")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: WelcomeView(setInbox: setInbox) { [weak self] in
            self?.window.close()
        })
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        Shortcuts.shared.stopRecording()
        Welcome.shared = nil
        onClose()
    }

    // Not key any more, so the keys pressed next are not for a shortcut field.
    func windowDidResignKey(_ notification: Notification) {
        Shortcuts.shared.stopRecording()
    }
}

// MARK: The steps

private enum Step: Int, CaseIterable {
    case line, bringDown, capture, gestures, scissors, start

    var title: String {
        switch self {
        case .line: L("Welcome to Clipline")
        case .bringDown: L("Out of sight, within reach")
        case .capture: L("Its own screenshot tool")
        case .gestures: L("A gesture for everything")
        case .scissors: L("Snip to clear")
        case .start: L("You’re all set")
        }
    }

    var text: String {
        switch self {
        case .line:
            L("Every screenshot you take hangs on a line at the top of the screen, ready to copy, mark up or drag where it needs to go.")
        case .bringDown:
            L("Rest the pointer in the middle of the menu bar and the line slides down. Move away and it tucks back up.")
        case .capture:
            L("The screen holds still. Click a window to take it, or drag out an area. Press Return and it hangs on the line.")
        case .gestures:
            L("Click a photo to copy it. Press and hold to mark it up. Drag it into an app to send it, or into a folder to keep it.")
        case .scissors:
            L("Hold the rope beside the clips and sweep sideways: every photo the scissors pass falls. Undo hangs them back.")
        case .start:
            L("Clipline lives in the menu bar. Its menu holds every setting, and this welcome if you want to see it again.")
        }
    }

    /// The shortcut that goes with the step, which can be changed right there.
    var shortcut: Shortcuts.Kind? {
        switch self {
        case .bringDown: .line
        case .capture: .capture
        default: nil
        }
    }

    /// How long the scene runs before it starts over.
    var loop: Double {
        switch self {
        case .line: 7.5
        case .bringDown: 6
        case .capture: 7.5
        case .gestures: 9.5
        case .scissors: 7.5
        case .start: 1000
        }
    }

    @ViewBuilder func scene(_ t: Double) -> some View {
        switch self {
        case .line: HangScene(t: t)
        case .bringDown: BringDownScene(t: t)
        case .capture: CaptureScene(t: t)
        case .gestures: GestureScene(t: t)
        case .scissors: ScissorsScene(t: t)
        case .start: RestScene(t: t)
        }
    }
}

struct WelcomeView: View {
    static let size = NSSize(width: 640, height: 580)

    let setInbox: (Bool) -> Void
    let close: () -> Void

    @State private var step = Step.line
    @State private var started = Date()
    @State private var inbox = Inbox.isEnabled

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(started).truncatingRemainder(dividingBy: step.loop)
                step.scene(t)
            }
            .frame(width: Stage.width, height: Stage.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .id(step)
            .transition(.opacity)
            .padding(.top, 40)

            VStack(spacing: 10) {
                Text(step.title)
                    .font(.system(size: 22, weight: .semibold))
                Text(step.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470)
                if let kind = step.shortcut {
                    HStack(alignment: .top, spacing: 10) {
                        Text(kind.title)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 30)
                        ShortcutField(kind)
                    }
                    .padding(.top, 2)
                }
                if step == .start {
                    inboxChoice
                        .padding(.top, 6)
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 40)
            .id(step.rawValue)
            .transition(.opacity)

            Spacer(minLength: 0)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.easeInOut(duration: 0.25), value: step)
        .onChange(of: step) { _, _ in started = Date() }
        .onChange(of: inbox) { _, on in setInbox(on) }
    }

    private var inboxChoice: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Handle screenshots"))
                    .font(.system(size: 13, weight: .semibold))
                Text(L("Screenshots hang instantly and skip the Desktop"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(L("Your screenshot settings come back when you turn it off or quit Clipline."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $inbox)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var footer: some View {
        HStack {
            // Skip passes the scenes, not the last step's choice.
            Button(L("Skip")) { step = .start }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .opacity(step == .start ? 0 : 1)
                .disabled(step == .start)
                .frame(width: 150, alignment: .leading)

            Spacer()
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.primary.opacity(0.75) : Color.primary.opacity(0.18))
                        .frame(width: 6, height: 6)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { step = s }
                }
            }
            Spacer()

            HStack(spacing: 8) {
                if step != .line {
                    Button(L("Back")) {
                        if let back = Step(rawValue: step.rawValue - 1) { step = back }
                    }
                    .controlSize(.large)
                }
                Button(step == .start ? L("Get Started") : L("Continue")) {
                    if let next = Step(rawValue: step.rawValue + 1) { step = next } else { close() }
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }
}

private struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5)
            )
    }
}

// MARK: Timing

/// 0 until `a`, 1 from `b`, eased in between.
private func ramp(_ t: Double, _ a: Double, _ b: Double) -> CGFloat {
    let x = min(1, max(0, (t - a) / (b - a)))
    return CGFloat(x * x * (3 - 2 * x))
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ f: CGFloat) -> CGFloat { a + (b - a) * f }

private func mix(_ a: CGPoint, _ b: CGPoint, _ f: CGFloat) -> CGPoint {
    CGPoint(x: mix(a.x, b.x, f), y: mix(a.y, b.y, f))
}

/// Every scene fades in at the start and out before it loops.
private func fade(_ t: Double, loop: Double) -> Double {
    Double(ramp(t, 0, 0.3) * (1 - ramp(t, loop - 0.5, loop - 0.05)))
}

// MARK: The little desktop

/// A small screen: wallpaper, a couple of windows and the menu bar, with the
/// line drawn the way the real one hangs.
private enum Stage {
    static let width: CGFloat = 560
    static let height: CGFloat = 300
    static let menuBar: CGFloat = 16
    static let ropeTop: CGFloat = 26
    static let sag: CGFloat = 9
    static let spacing: CGFloat = 84
    static let card = CGSize(width: 66, height: 46)

    static func ropeY(_ x: CGFloat) -> CGFloat {
        let f = x / width
        return ropeTop + 4 * sag * f * (1 - f)
    }

    /// Where the photo in `slot` of `count` grips the rope.
    static func clipX(_ slot: CGFloat, of count: Int) -> CGFloat {
        width / 2 + (slot - CGFloat(count - 1) / 2) * spacing
    }

    /// The middle of a photo hanging from `x`.
    static func cardCenter(_ x: CGFloat) -> CGPoint {
        CGPoint(x: x, y: ropeY(x) + 4 + (card.height + 6) / 2)
    }

    /// How far a tucked away line sits above, out of sight under the menu bar.
    static let tucked: CGFloat = -100

    static let windowA = CGRect(x: 54, y: 70, width: 250, height: 168)
    static let windowB = CGRect(x: 288, y: 104, width: 222, height: 150)
}

private struct Desktop<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    /// The menu bar's Clipline icon lit up, as when its menu is open.
    var litIcon = false
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.16, green: 0.19, blue: 0.32), Color(red: 0.30, green: 0.20, blue: 0.34)]
                    : [Color(red: 0.62, green: 0.75, blue: 0.95), Color(red: 0.93, green: 0.78, blue: 0.86)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            MiniWindow(lines: 5).frame(width: Stage.windowA.width, height: Stage.windowA.height)
                .offset(x: Stage.windowA.minX, y: Stage.windowA.minY)
            MiniWindow(lines: 3, chart: true).frame(width: Stage.windowB.width, height: Stage.windowB.height)
                .offset(x: Stage.windowB.minX, y: Stage.windowB.minY)
            content
            MenuBar(litIcon: litIcon)
        }
        .frame(width: Stage.width, height: Stage.height, alignment: .topLeading)
    }
}

private struct MenuBar: View {
    var litIcon: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "applelogo").font(.system(size: 8.5, weight: .semibold))
            ForEach([22.0, 18, 26, 20], id: \.self) { w in
                Capsule().fill(Color.primary.opacity(0.35)).frame(width: w, height: 3.5)
            }
            Spacer()
            Image(systemName: "tshirt")
                .font(.system(size: 8.5, weight: .medium))
                .padding(.horizontal, 4)
                .frame(height: 13)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(litIcon ? 0.16 : 0)))
            Image(systemName: "wifi").font(.system(size: 8, weight: .semibold))
            Capsule().fill(Color.primary.opacity(0.35)).frame(width: 28, height: 3.5)
        }
        .foregroundStyle(Color.primary.opacity(0.8))
        .padding(.horizontal, 10)
        .frame(width: Stage.width, height: Stage.menuBar)
        .background(.bar)
    }
}

private struct MiniWindow: View {
    let lines: Int
    var chart = false

    private static let widths: [CGFloat] = [150, 120, 170, 95, 140]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in
                    Circle().fill(c.opacity(0.75)).frame(width: 6, height: 6)
                }
            }
            .padding(8)
            VStack(alignment: .leading, spacing: 7) {
                if chart {
                    HStack(alignment: .bottom, spacing: 7) {
                        ForEach([0.45, 0.7, 0.55, 0.9, 0.65], id: \.self) { h in
                            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.55))
                                .frame(width: 18, height: 54 * h)
                        }
                    }
                    .frame(height: 56, alignment: .bottom)
                }
                ForEach(0..<lines, id: \.self) { n in
                    Capsule().fill(Color.primary.opacity(0.13))
                        .frame(width: Self.widths[n % Self.widths.count], height: 5)
                }
            }
            .padding(.horizontal, 14)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
    }
}

/// What a photo shows: each one a different little screenshot.
private struct PhotoArt: View {
    let kind: Int

    var body: some View {
        switch kind % 4 {
        case 0:
            ZStack(alignment: .bottomLeading) {
                Color(red: 0.95, green: 0.96, blue: 0.99)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach([0.4, 0.75, 0.55, 1.0], id: \.self) { h in
                        RoundedRectangle(cornerRadius: 1).fill(Color(red: 0.35, green: 0.55, blue: 0.95))
                            .frame(width: 8, height: 26 * h)
                    }
                }
                .padding(8)
            }
        case 1:
            ZStack {
                LinearGradient(colors: [Color(red: 1, green: 0.74, blue: 0.45), Color(red: 0.93, green: 0.42, blue: 0.5)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(Color.white.opacity(0.85)).frame(width: 14, height: 14).offset(x: 12, y: -6)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 40)); p.addLine(to: CGPoint(x: 22, y: 22))
                    p.addLine(to: CGPoint(x: 38, y: 34)); p.addLine(to: CGPoint(x: 52, y: 24))
                    p.addLine(to: CGPoint(x: 80, y: 44)); p.addLine(to: CGPoint(x: 0, y: 60))
                }
                .fill(Color(red: 0.36, green: 0.2, blue: 0.4).opacity(0.7))
            }
        case 2:
            ZStack(alignment: .topLeading) {
                Color(red: 0.13, green: 0.14, blue: 0.18)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array([(28.0, Color.pink), (40, Color.cyan), (22, Color.green), (34, Color.orange)].enumerated()),
                            id: \.offset) { _, line in
                        Capsule().fill(line.1.opacity(0.8)).frame(width: line.0, height: 3)
                    }
                }
                .padding(7)
            }
        default:
            ZStack(alignment: .topLeading) {
                Color.white
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(Color.black.opacity(0.55)).frame(width: 30, height: 4)
                    ForEach([44.0, 38, 46, 26], id: \.self) { w in
                        Capsule().fill(Color.black.opacity(0.16)).frame(width: w, height: 3)
                    }
                }
                .padding(7)
            }
        }
    }
}

/// A photo in its glass frame, at any size, for one that is flying.
private struct Card: View {
    let kind: Int
    var size = Stage.card

    var body: some View {
        PhotoArt(kind: kind)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
            .padding(3)
            .glassFrame(cornerRadius: 6.5)
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }
}

/// A photo hanging from its clip, swaying a little. Its top centre is the
/// point where the clip grips the rope.
private struct Hanging<Overlay: View>: View {
    let kind: Int
    let t: Double
    var tilt: Double = 0
    @ViewBuilder var overlay: Overlay

    var body: some View {
        VStack(spacing: -10) {
            Clothespin()
                .scaleEffect(0.72)
                .frame(width: 7, height: 19)
                .zIndex(1)
            Card(kind: kind)
                .overlay { overlay }
        }
        .rotationEffect(.degrees(tilt + sin(t * 1.4 + Double(kind)) * 0.9), anchor: .top)
    }
}

extension Hanging where Overlay == EmptyView {
    init(kind: Int, t: Double, tilt: Double = 0) {
        self.init(kind: kind, t: t, tilt: tilt) { EmptyView() }
    }
}

private struct MiniRope: View {
    var body: some View {
        let path = Path { p in
            p.move(to: CGPoint(x: -10, y: Stage.ropeTop))
            p.addQuadCurve(to: CGPoint(x: Stage.width + 10, y: Stage.ropeTop),
                           control: CGPoint(x: Stage.width / 2, y: Stage.ropeTop + 2 * Stage.sag))
        }
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.2).offset(y: 1).blur(radius: 1)
            path.stroke(Color(white: 0.55), lineWidth: 1)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.35).offset(y: -0.3)
        }
        .frame(width: Stage.width, height: Stage.height, alignment: .topLeading)
    }
}

/// Photos hanging at their clips' places on the rope.
private struct MiniLine: View {
    let t: Double
    /// Each photo: what it shows and where its clip grips the rope.
    let photos: [(kind: Int, x: CGFloat)]

    var body: some View {
        ZStack(alignment: .topLeading) {
            MiniRope()
            ForEach(photos, id: \.kind) { photo in
                Hanging(kind: photo.kind, t: t, tilt: [-2, 1.5, -1, 2][photo.kind % 4])
                    .fixedSize()
                    .position(hangingCenter(photo.x))
            }
        }
        .frame(width: Stage.width, height: Stage.height, alignment: .topLeading)
    }
}

/// Where to put a `Hanging` so its clip grips the rope at `x`.
private func hangingCenter(_ x: CGFloat) -> CGPoint {
    // The clip's top sits a little above the rope; the card hangs below.
    let height = 19 - 10 + Stage.card.height + 6
    return CGPoint(x: x, y: Stage.ropeY(x) - 5 + height / 2)
}

private struct Pointer: View {
    var pressed = false

    private static let arrow = Path { p in
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 0, y: 15.5))
        p.addLine(to: CGPoint(x: 3.8, y: 11.9))
        p.addLine(to: CGPoint(x: 6.4, y: 17.6))
        p.addLine(to: CGPoint(x: 8.9, y: 16.5))
        p.addLine(to: CGPoint(x: 6.4, y: 10.9))
        p.addLine(to: CGPoint(x: 11.3, y: 10.9))
        p.closeSubpath()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Self.arrow.fill(Color.black)
            Self.arrow.stroke(Color.white, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
        .frame(width: 13, height: 19, alignment: .topLeading)
        .scaleEffect(pressed ? 0.86 : 1, anchor: .topLeading)
        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
    }
}

extension View {
    /// Places a pointer so its tip is at `p`.
    fileprivate func tip(at p: CGPoint) -> some View {
        position(x: p.x + 6.5, y: p.y + 9.5)
    }
}

/// A label for what the scene is acting out, at the bottom of the stage.
private struct Caption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .glassFrame(capsule: true)
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
    }
}

/// The real line's scissors, a little smaller.
private struct MiniScissors: View {
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
        }
        .frame(width: 30, height: 22, alignment: .topLeading)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
    }
}

private let cutTint = Color(red: 1, green: 0.62, blue: 0.26)

// MARK: The scenes

/// Three screenshots, one after another, each flashing where it was taken
/// and flying up to its place on the line.
private struct HangScene: View {
    let t: Double

    private static let shots: [(kind: Int, from: CGRect, at: Double)] = [
        (0, CGRect(x: 300, y: 118, width: 150, height: 92), 0.5),
        (3, CGRect(x: 66, y: 98, width: 170, height: 110), 2.4),
        (1, CGRect(x: 380, y: 150, width: 110, height: 90), 4.3),
    ]

    var body: some View {
        Desktop {
            let landed = Self.shots.enumerated().filter { t >= $0.element.at + 0.95 }
            let count = max(landed.count, 1)
            MiniLine(t: t, photos: landed.map { n, shot in
                (kind: shot.kind, x: Stage.clipX(CGFloat(n), of: count))
            })
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: landed.count)

            ForEach(Array(Self.shots.enumerated()), id: \.offset) { n, shot in
                let flash = ramp(t, shot.at, shot.at + 0.08) * (1 - ramp(t, shot.at + 0.1, shot.at + 0.35))
                Rectangle().fill(Color.white.opacity(0.75 * Double(flash)))
                    .frame(width: shot.from.width, height: shot.from.height)
                    .position(x: shot.from.midX, y: shot.from.midY)

                if t >= shot.at + 0.2 && t < shot.at + 0.95 {
                    let f = ramp(t, shot.at + 0.2, shot.at + 0.95)
                    let to = Stage.cardCenter(Stage.clipX(CGFloat(n), of: n + 1))
                    let lift = sin(Double(f) * .pi) * 30
                    Card(kind: shot.kind, size: CGSize(width: mix(shot.from.width - 6, Stage.card.width, f),
                                                       height: mix(shot.from.height - 6, Stage.card.height, f)))
                        .position(x: mix(shot.from.midX, to.x, f), y: mix(shot.from.midY, to.y, f) - lift)
                }
            }
        }
        .opacity(fade(t, loop: Step.line.loop))
    }
}

/// The pointer rests in the middle of the menu bar, the line slides down;
/// the pointer leaves and it tucks back up.
private struct BringDownScene: View {
    let t: Double

    var body: some View {
        let start = CGPoint(x: 400, y: 210), zone = CGPoint(x: 282, y: 4), away = CGPoint(x: 360, y: 250)
        let pointer = t < 3 ? mix(start, zone, ramp(t, 0.4, 1.3)) : mix(zone, away, ramp(t, 3.1, 3.9))
        let down = ramp(t, 1.45, 1.75) * (1 - ramp(t, 4.0, 4.25))
        let inZone = t > 1.2 && t < 3.15

        Desktop {
            MiniLine(t: t, photos: [(0, Stage.clipX(0, of: 3)), (3, Stage.clipX(1, of: 3)), (1, Stage.clipX(2, of: 3))])
                .offset(y: Stage.tucked * (1 - down))
        }
        .overlay(alignment: .top) {
            // The middle of the menu bar, where resting brings the line down.
            Capsule()
                .fill(Color.accentColor.opacity(inZone ? 0.35 : 0))
                .frame(width: 168, height: 6)
                .blur(radius: 2)
                .padding(.top, 2)
                .animation(.easeOut(duration: 0.2), value: inZone)
        }
        .overlay(alignment: .topLeading) {
            Pointer().tip(at: pointer)
        }
        .opacity(fade(t, loop: Step.bringDown.loop))
    }
}

/// The screen holds still, the window under the pointer lights up, an area
/// is dragged out, Return, and it flies to the line.
private struct CaptureScene: View {
    let t: Double

    var body: some View {
        let frozen = ramp(t, 0.5, 0.7) * (1 - ramp(t, 4.0, 4.2))
        let a = CGPoint(x: 312, y: 124), b = CGPoint(x: 470, y: 222)
        let pointer: CGPoint = {
            if t < 2.1 { return mix(CGPoint(x: 200, y: 250), CGPoint(x: 180, y: 150), ramp(t, 1.0, 1.7)) }
            if t < 2.7 { return mix(CGPoint(x: 180, y: 150), a, ramp(t, 2.1, 2.6)) }
            return mix(a, b, ramp(t, 2.8, 3.5))
        }()
        let hoverA = t > 1.6 && t < 2.2
        let dragging = t >= 2.8 && t < 4.0
        let selection = CGRect(x: a.x, y: a.y, width: pointer.x - a.x, height: pointer.y - a.y)
        let landed = t >= 4.9
        let shortcut = Shortcuts.shared.capture?.display

        let count = landed ? 3 : 2
        let hung: [(kind: Int, x: CGFloat)] = [(2, Stage.clipX(0, of: count)), (3, Stage.clipX(1, of: count))]
        let photos = landed ? hung + [(kind: 0, x: Stage.clipX(2, of: 3))] : hung

        Desktop {
            MiniLine(t: t, photos: photos)
                .offset(y: Stage.tucked * (1 - ramp(t, 4.0, 4.25)))
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: landed)

            // Frozen: the screen dims, except the window or area being taken.
            Color.black.opacity(0.28 * Double(frozen))
                .reverseMask {
                    if hoverA {
                        RoundedRectangle(cornerRadius: 8).frame(width: Stage.windowA.width, height: Stage.windowA.height)
                            .position(x: Stage.windowA.midX, y: Stage.windowA.midY)
                    } else if dragging, selection.width > 1 {
                        Rectangle().frame(width: selection.width, height: selection.height)
                            .position(x: selection.midX, y: selection.midY)
                    }
                }
            if hoverA && frozen > 0 {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: Stage.windowA.width, height: Stage.windowA.height)
                    .position(x: Stage.windowA.midX, y: Stage.windowA.midY)
            }
            if dragging, selection.width > 1 {
                Rectangle().strokeBorder(Color.white, lineWidth: 1)
                    .frame(width: selection.width, height: selection.height)
                    .position(x: selection.midX, y: selection.midY)
            }
            if let shortcut, t > 0.2, t < 1.4 {
                Keycap(text: shortcut).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .scaleEffect(1 + 0.15 * (1 - ramp(t, 0.2, 0.4)))
                    .position(x: Stage.width / 2, y: 60)
            }
            if t > 3.6, t < 4.3 {
                Keycap(text: "↩").background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                    .position(x: b.x + 26, y: b.y + 18)
            }
            if t >= 4.1 && t < 4.9 {
                let f = ramp(t, 4.1, 4.9)
                let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                let to = Stage.cardCenter(Stage.clipX(2, of: 3))
                Card(kind: 0, size: CGSize(width: mix(rect.width - 6, Stage.card.width, f),
                                           height: mix(rect.height - 6, Stage.card.height, f)))
                    .position(x: mix(rect.midX, to.x, f), y: mix(rect.midY, to.y, f) - sin(Double(f) * .pi) * 24)
            }
        }
        .overlay(alignment: .topLeading) {
            if t < 4.1 { Pointer(pressed: dragging && t < 3.6).tip(at: pointer) }
        }
        .opacity(fade(t, loop: Step.capture.loop))
    }
}

/// Click copies, press and hold marks up, a drag into a folder keeps it.
private struct GestureScene: View {
    let t: Double

    var body: some View {
        let mid = Stage.clipX(1, of: 3)
        let card = Stage.cardCenter(mid)
        let folder = CGPoint(x: 470, y: 240)
        let pressed = (t > 1.1 && t < 1.3) || (t > 2.8 && t < 4.6) || (t > 5.8 && t < 7.2)
        let carried = ramp(t, 6.0, 7.0)
        let into = ramp(t, 7.1, 7.4)
        let gone = t >= 7.4
        let pointer: CGPoint = {
            if t < 5.8 { return mix(CGPoint(x: 230, y: 250), CGPoint(x: card.x + 6, y: card.y + 4), ramp(t, 0.3, 0.9)) }
            return mix(CGPoint(x: card.x + 6, y: card.y + 4), CGPoint(x: folder.x + 4, y: folder.y - 2), carried)
        }()
        let caption: String? = {
            if t > 0.3 && t < 2.4 { return L("Click to copy") }
            if t > 2.5 && t < 5.3 { return L("Press and hold to mark up") }
            if t > 5.4 && t < 8.6 { return L("Drag into a folder to keep it") }
            return nil
        }()
        let others: [(kind: Int, x: CGFloat)] = gone
            ? [(2, Stage.clipX(0, of: 2)), (1, Stage.clipX(1, of: 2))]
            : [(2, Stage.clipX(0, of: 3)), (1, Stage.clipX(2, of: 3))]

        Desktop {
            MiniLine(t: t, photos: others)
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: gone)

            if !gone {
                let at = mix(hangingCenter(mid), CGPoint(x: folder.x, y: folder.y - 10), carried)
                Hanging(kind: 0, t: t, tilt: -1 + 6 * Double(carried)) {
                    Marks(drawn: ramp(t, 3.3, 4.1))
                }
                .fixedSize()
                .scaleEffect(1 - 0.75 * into)
                .opacity(1 - Double(into))
                .position(at)
            }
            if t > 1.2 && t < 2.3 {
                Text(L("Copied"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.9)))
                    .position(x: card.x, y: card.y + Stage.card.height / 2 + 18)
                    .transition(.opacity)
            }
            if t > 2.8 && t < 3.3 {
                // The hold filling up.
                Circle().trim(from: 0, to: ramp(t, 2.8, 3.25))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 26, height: 26)
                    .shadow(color: .black.opacity(0.3), radius: 2)
                    .position(x: pointer.x - 1, y: pointer.y + 1)
            }
            if t > 5.0 && t < 8.6 {
                Image(systemName: "folder.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color(red: 0.36, green: 0.65, blue: 0.98))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                    .scaleEffect(1 + 0.12 * sin(Double(ramp(t, 7.2, 7.6)) * .pi))
                    .position(folder)
            }
            if let caption {
                Caption(text: caption)
                    .position(x: Stage.width / 2, y: Stage.height - 26)
            }
        }
        .overlay(alignment: .topLeading) {
            if t < 8.8 { Pointer(pressed: pressed).tip(at: pointer) }
        }
        .animation(.easeOut(duration: 0.2), value: caption)
        .opacity(fade(t, loop: Step.gestures.loop))
    }
}

/// A red box and an arrow, drawn on the photo as it is marked up.
private struct Marks: View {
    let drawn: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .trim(from: 0, to: min(1, drawn * 2))
                .stroke(Color.red, lineWidth: 1.6)
                .frame(width: 26, height: 20)
                .offset(x: 34, y: 8)
            Path { p in
                p.move(to: CGPoint(x: 10, y: 38))
                p.addLine(to: CGPoint(x: 31, y: 24))
                p.move(to: CGPoint(x: 31, y: 24))
                p.addLine(to: CGPoint(x: 24, y: 25))
                p.move(to: CGPoint(x: 31, y: 24))
                p.addLine(to: CGPoint(x: 28, y: 30.5))
            }
            .trim(from: 0, to: max(0, drawn * 2 - 1))
            .stroke(Color.red, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Stage.card.width + 6, height: Stage.card.height + 6, alignment: .topLeading)
    }
}

/// The scissors sweep along the rope, every photo they pass falls, and
/// Undo hangs them back.
private struct ScissorsScene: View {
    let t: Double

    private static let kinds = [2, 0, 3, 1]

    var body: some View {
        let xs = Self.kinds.indices.map { Stage.clipX(CGFloat($0), of: Self.kinds.count) }
        let from = xs[0] - 36, to = xs[xs.count - 1] + 30
        let cutX = mix(from, to, ramp(t, 1.3, 2.7))
        let onRope = t >= 1.0 && t < 2.9
        let undoAt = 4.3
        let back = t >= undoAt + 0.1
        let pill = CGPoint(x: Stage.width / 2, y: Stage.height - 30)
        let pointer: CGPoint = {
            if t < 1.0 { return mix(CGPoint(x: 170, y: 250), CGPoint(x: from, y: Stage.ropeY(from)), ramp(t, 0.2, 0.9)) }
            if t < 2.9 { return CGPoint(x: cutX, y: Stage.ropeY(cutX)) }
            return mix(CGPoint(x: to, y: Stage.ropeY(to)), CGPoint(x: pill.x + 46, y: pill.y - 2), ramp(t, 3.3, 4.1))
        }()

        Desktop {
            MiniRope()
            if onRope {
                Path { p in
                    p.move(to: CGPoint(x: -10, y: Stage.ropeTop))
                    p.addQuadCurve(to: CGPoint(x: Stage.width + 10, y: Stage.ropeTop),
                                   control: CGPoint(x: Stage.width / 2, y: Stage.ropeTop + 2 * Stage.sag))
                }
                .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .blur(radius: 3)
            }
            if t >= 1.3 && t < 3.4 {
                // The cut so far, fading behind the scissors.
                Path { p in
                    let start = max(from, cutX - 200)
                    p.move(to: CGPoint(x: start, y: Stage.ropeY(start)))
                    var x = start
                    while x < cutX { x = min(cutX, x + 6); p.addLine(to: CGPoint(x: x, y: Stage.ropeY(x))) }
                }
                .stroke(LinearGradient(colors: [cutTint.opacity(0), cutTint], startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .opacity(1 - Double(ramp(t, 2.8, 3.4)))
            }

            ForEach(Array(Self.kinds.enumerated()), id: \.offset) { n, kind in
                let x = xs[n]
                // The moment the scissors reach this clip.
                let snap = 1.3 + 1.4 * Double((x - from) / (to - from))
                let dt = t - snap
                if back {
                    let drop = ramp(t, undoAt + 0.1 + 0.06 * Double(n), undoAt + 0.45 + 0.06 * Double(n))
                    Hanging(kind: kind, t: t, tilt: [-2, 1.5, -1, 2][n])
                        .fixedSize()
                        .opacity(Double(drop))
                        .position(x: hangingCenter(x).x, y: hangingCenter(x).y - 30 * (1 - drop))
                } else if dt < 0 {
                    Hanging(kind: kind, t: t, tilt: [-2, 1.5, -1, 2][n])
                        .fixedSize()
                        .position(hangingCenter(x))
                } else if dt < 0.8 {
                    Hanging(kind: kind, t: t, tilt: [-2, 1.5, -1, 2][n] + dt * (n % 2 == 0 ? 90 : -90))
                        .fixedSize()
                        .opacity(1 - dt / 0.8)
                        .position(x: hangingCenter(x).x + CGFloat(dt) * 20,
                                  y: hangingCenter(x).y + CGFloat(0.5 * 700 * dt * dt))
                }
                if dt >= 0 && dt < 0.35 && !back {
                    Spark(f: dt / 0.35).position(x: x, y: Stage.ropeY(x))
                }
            }

            if onRope && t >= 1.0 {
                MiniScissors().position(x: pointer.x - 12, y: pointer.y)
            }
            if t >= 3.0 && t < undoAt + 0.3 {
                UndoBadge(pressed: t > undoAt - 0.1)
                    .opacity(Double(ramp(t, 3.0, 3.25)) * (1 - Double(ramp(t, undoAt, undoAt + 0.3))))
                    .position(pill)
            }
        }
        .overlay(alignment: .topLeading) {
            if !onRope && t < 6.6 { Pointer(pressed: t > undoAt - 0.1 && t < undoAt + 0.1).tip(at: pointer) }
        }
        .opacity(fade(t, loop: Step.scissors.loop))
    }
}

private struct Spark: View {
    let f: Double

    var body: some View {
        ZStack {
            ForEach([-70.0, -25, 20, 65, 150, 210], id: \.self) { angle in
                Capsule().fill(cutTint)
                    .frame(width: 1.3, height: 4.5)
                    .offset(y: -4 - 8 * f)
                    .rotationEffect(.degrees(angle))
            }
        }
        .opacity(1 - f)
    }
}

private struct UndoBadge: View {
    let pressed: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors").font(.system(size: 10, weight: .semibold))
            Text(String(format: L("%d taken down"), 4)).font(.system(size: 11, weight: .medium))
            Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 0.5, height: 14)
            Text(L("Undo"))
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 21)
                .background(Color.primary.opacity(pressed ? 0.18 : 0.08), in: Capsule())
        }
        .padding(.leading, 11)
        .padding(.trailing, 5)
        .frame(height: 31)
        .glassFrame(capsule: true)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .fixedSize()
    }
}

/// The line at rest under the menu bar, its icon lit: where everything is.
private struct RestScene: View {
    let t: Double

    var body: some View {
        Desktop(litIcon: true) {
            MiniLine(t: t, photos: [(2, Stage.clipX(0, of: 3)), (0, Stage.clipX(1, of: 3)), (1, Stage.clipX(2, of: 3))])
        }
        .opacity(Double(ramp(t, 0, 0.3)))
    }
}

extension View {
    /// Cuts the shape out of this view, the way a dimmed screen leaves the
    /// selection clear.
    fileprivate func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
