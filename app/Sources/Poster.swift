import AppKit
import SwiftUI

/// Kwadratowe okno bez ramki: okladka na calosc, napisy na okladce, przyciski po najechaniu kursorem.
final class PosterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }

    /// Wywolywane po kazdym schowaniu okna (Esc, klik obok, klik w pozycje w pasku).
    var onHide: (() -> Void)?

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        onHide?()
    }
}

/// Stan widoku (najechanie, przeciaganie). Zamiast @State, bo w SwiftUI z macOS 27 @State jest makrem,
/// ktorego Command Line Tools nie maja - aplikacja buduje sie samym swiftc.
@MainActor
final class PosterUI: ObservableObject {
    @Published var hover = false
    @Published var hovered: String?
    @Published var dragging: Double?
}

@MainActor
final class PosterController {
    static let side: CGFloat = 460
    private let panel: PosterPanel
    private var placed = false

    private let favorites: FavoritesStore

    init(np: NowPlaying, favorites: FavoritesStore) {
        self.favorites = favorites
        panel = PosterPanel(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: PosterView(np: np, favorites: favorites, ui: PosterUI(), side: Self.side))
        host.frame = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        panel.contentView = host
        panel.onHide = { [weak self] in
            MainActor.assumeIsolated { self?.removeClickMonitor() }
        }
    }

    /// Klik w dowolne miejsce poza oknem chowa je. Panel nie aktywuje aplikacji, wiec resignKey nie jest pewny;
    /// globalny monitor myszy nie wymaga zadnych uprawnien systemowych.
    /// Klik w nasza pozycje w pasku pomijamy: chowa go akcja przycisku (toggle). Bez tego monitor chowalby okno
    /// przy mouseDown, a akcja przy mouseUp otwierala je z powrotem.
    private var clickMonitor: Any?
    private var statusFrame: NSRect = .zero

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.statusFrame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    /// Pierwsze otwarcie: pod utworem w pasku. Potem okno zostaje tam, gdzie je przesunieto.
    func toggle(below statusWindow: NSWindow?) {
        if panel.isVisible { panel.orderOut(nil); return }
        if let item = statusWindow { statusFrame = item.frame }
        if !placed, let item = statusWindow, let screen = item.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let x = min(max(vf.minX + 8, item.frame.midX - Self.side / 2), vf.maxX - Self.side - 8)
            panel.setFrameOrigin(NSPoint(x: x, y: vf.maxY - Self.side - 8))
            placed = true
        }
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        installClickMonitor()
        favorites.refreshIfStale()
    }
}

struct PosterView: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var favorites: FavoritesStore
    @ObservedObject var ui: PosterUI
    let side: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            cover
            LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                   .init(color: .black.opacity(0.35), location: 0.4),
                                   .init(color: .black.opacity(0.82), location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: side * (ui.hover ? 0.8 : 0.62))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
            if let t = np.track {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(t.title)
                                .font(.system(size: 26, weight: .bold))
                                .tracking(-0.5)
                                .lineLimit(2)
                            Text(t.artist)
                                .font(.system(size: 16))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                                .padding(.top, 4)
                            if !t.album.isEmpty && t.album != t.title {
                                Text(t.album)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                                    .padding(.top, 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HeartButton(np: np, favorites: favorites)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
                    if ui.hover {
                        Dock(np: np, ui: ui)
                            .padding(.top, 16)
                            .transition(.opacity.combined(with: .offset(y: 10)))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.bottom, ui.hover ? 16 : 22)
                if !ui.hover {
                    EdgeProgress(np: np).transition(.opacity)
                }
            } else {
                EmptyState()
            }
            if let msg = favorites.toast {
                Text(msg)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.black.opacity(0.72)))
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.2), value: favorites.toast)
        .frame(width: side, height: side)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .gesture(WindowDragGesture())
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { ui.hover = h } }
    }

    @ViewBuilder private var cover: some View {
        if let art = np.artwork {
            Image(nsImage: art)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipped()
        } else {
            Color(white: 0.12)
        }
    }
}

private struct Dock: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var ui: PosterUI

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let d = np.track?.duration ?? 0
                let e = ui.dragging.map { $0 * d } ?? np.elapsed(at: ctx.date)
                VStack(spacing: 3) {
                    SeekBar(ui: ui, fraction: d > 0 ? e / d : 0) { f in np.seek(to: f * d) }
                    HStack {
                        Text(clock(e))
                        Spacer()
                        Text("-" + clock(max(0, d - e)))
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                }
            }
            HStack(spacing: 22) {
                ControlButton(ui: ui, id: "prev", symbol: "backward.fill") { np.previous() }
                PlayButton(ui: ui, playing: np.playing) { np.togglePlayPause() }
                ControlButton(ui: ui, id: "next", symbol: "forward.fill") { np.next() }
            }
            .padding(.top, 8)
        }
    }
}

/// Serduszko "dodaj do ulubionych w TIDAL-u". Zawsze widoczne; przygaszone, gdy numer utworu jest nieznany.
private struct HeartButton: View {
    @ObservedObject var np: NowPlaying
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        let id = np.trackID
        let liked = id.map { favorites.contains($0) && favorites.auth.loggedIn } ?? false
        let known = id != nil || !favorites.auth.loggedIn
        Button { favorites.heartTapped(np: np) } label: {
            ZStack {
                if favorites.working {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                } else {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .font(.system(size: 22, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: liked)
                        .opacity(id.map { favorites.busy.contains($0) } == true ? 0.6 : 1)
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .opacity(known ? 1 : 0.35)
        .help(!known ? "Track not found in TIDAL yet - click to look it up"
                     : (!favorites.auth.loggedIn ? "Log in to TIDAL to add favorites"
                        : (liked ? "Remove from TIDAL favorites" : "Add to TIDAL favorites")))
    }
}

private struct EdgeProgress: View {
    @ObservedObject var np: NowPlaying

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.15))
                    Rectangle().fill(Color(nsColor: np.accent))
                        .frame(width: g.size.width * np.fraction(at: ctx.date))
                }
            }
            .frame(height: 3)
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

private struct SeekBar: View {
    @ObservedObject var ui: PosterUI
    var fraction: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let f = min(1, max(0, fraction))
            let thick = ui.hovered == "seek" || ui.dragging != nil
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.92)).frame(width: f * g.size.width)
            }
            .frame(height: thick ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in ui.dragging = min(1, max(0, v.location.x / g.size.width)) }
                .onEnded { v in
                    ui.dragging = nil
                    onSeek(min(1, max(0, v.location.x / g.size.width)))
                })
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { ui.hovered = h ? "seek" : nil } }
        }
        .frame(height: 14)
    }
}

private struct ControlButton: View {
    @ObservedObject var ui: PosterUI
    let id: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(Circle().fill(.white.opacity(ui.hovered == id ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .onHover { h in ui.hovered = h ? id : nil }
    }
}

private struct PlayButton: View {
    @ObservedObject var ui: PosterUI
    let playing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 20, weight: .bold))
                .offset(x: playing ? 0 : 1.5)
                .foregroundStyle(Color(white: 0.07))
                .frame(width: 48, height: 48)
                .background(Circle().fill(.white))
                .scaleEffect(ui.hovered == "play" ? 1.04 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { ui.hovered = h ? "play" : nil } }
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note").font(.system(size: 40, weight: .light))
            Text("Nothing playing in TIDAL").font(.system(size: 15, weight: .semibold))
            Button("Open TIDAL") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/TIDAL.app")) }
        }
        .foregroundStyle(.white.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private func clock(_ s: Double) -> String {
    let t = Int(s.rounded(.down))
    return "\(t / 60):" + String(format: "%02d", t % 60)
}
