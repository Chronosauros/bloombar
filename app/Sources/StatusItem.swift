import AppKit
import Combine

/// Utwor w pasku menu: mala okladka, tytul i wykonawca. Lewy klik - okno, prawy - menu.
@MainActor
final class StatusController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu: NSMenu
    private let onClick: () -> Void
    private var bag = Set<AnyCancellable>()
    private let np: NowPlaying
    private let progress = ProgressLineView(frame: .zero)
    private var progressTimer: Timer?

    /// Wlacznik "Progress in Menu Bar" (domyslnie wlaczony, pamietany w UserDefaults).
    static let progressKey = "showMenuBarProgress"
    var progressEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.progressKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.progressKey)
            refreshProgress()
        }
    }

    init(np: NowPlaying, menu: NSMenu, onClick: @escaping () -> Void) {
        self.np = np
        self.menu = menu
        self.onClick = onClick
        super.init()
        UserDefaults.standard.register(defaults: [Self.progressKey: true])
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeading
            b.imageHugsTitle = true
            progress.frame = b.bounds
            progress.isHidden = true
            b.addSubview(progress)
        }
        np.$track.combineLatest(np.$playing, np.$artwork)
            .receive(on: RunLoop.main)
            .sink { [weak self] t, playing, art in
                self?.update(t, playing, art)
                self?.refreshProgress(playing: playing)
            }
            .store(in: &bag)
    }

    /// Fala postepu jest widoczna, gdy jest utwor i wlacznik jest wlaczony. Timer 2 razy na sekunde chodzi tylko wtedy;
    /// przy pauzie ulamek sie nie zmienia, wiec fala stoi, a slupki przy glowicy przestaja oddychac.
    private func refreshProgress(playing: Bool? = nil) {
        let on = progressEnabled && np.track != nil
        progress.isHidden = !on
        progress.playing = on && (playing ?? np.playing)
        guard on, let t = np.track else {
            progressTimer?.invalidate()
            progressTimer = nil
            return
        }
        progress.trackKey = t.title + "|" + t.artist
        progress.fraction = np.fraction()
        if progressTimer == nil {
            let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.progress.fraction = self?.np.fraction() ?? 0 }
            }
            RunLoop.main.add(t, forMode: .common)
            progressTimer = t
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
        } else {
            onClick()
        }
    }

    private func update(_ t: Track?, _ playing: Bool, _ art: NSImage?) {
        guard let b = item.button else { return }
        guard let t else {
            b.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "TIDAL")
            b.attributedTitle = NSAttributedString(string: "")
            placeProgress()
            return
        }
        b.image = art.map { Self.thumb($0, dimmed: !playing) }
            ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: "TIDAL")
        let font = NSFont.menuBarFont(ofSize: 0)
        // Tekst o 3,5 pt wyzej niz srodek paska: miejsce na wysokie slupki postepu przy dolnej krawedzi.
        // Pauze pokazuje okladka (przygaszona, ze znakiem pauzy) - tytul zostaje czytelny.
        let s = NSMutableAttributedString(string: " " + Self.clip(t.title, 28), attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .baselineOffset: Self.textLift,
        ])
        if !t.artist.isEmpty {
            s.append(NSAttributedString(string: "  ·  " + Self.clip(t.artist, 20), attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .baselineOffset: Self.textLift,
            ]))
        }
        b.attributedTitle = s
        placeProgress()
    }

    private static let textLift: CGFloat = 3.5

    /// Fala postepu biegnie tylko pod tekstem: zaczyna sie za okladka, ktora stoi po lewej na cala wysokosc paska.
    private func placeProgress() {
        func layoutLine() {
            guard let b = item.button else { return }
            let imageEnd = b.image == nil ? 0 : (b.cell?.imageRect(forBounds: b.bounds).maxX ?? 0)
            progress.leading = (imageEnd + 3).rounded()
        }
        layoutLine()
        // Uklad przycisku ustala sie dopiero po zmianie obrazu - poprawka w nastepnym obiegu petli.
        DispatchQueue.main.async { MainActor.assumeIsolated { layoutLine() } }
    }

    /// Odstep okladki od tytulu: przezroczysty margines po prawej stronie obrazu.
    private static let coverGap: CGFloat = 6

    /// Okladka na cala wysokosc pozycji w pasku menu (macOS daje jej `thickness`, np. 24 pt w pasku 30 pt),
    /// z lekko zaokraglonymi rogami.
    private static func thumb(_ image: NSImage, dimmed: Bool) -> NSImage {
        let side = max(18, NSStatusBar.system.thickness)
        return NSImage(size: NSSize(width: side + coverGap, height: side), flipped: false) { _ in
            let r = NSRect(x: 0, y: 0, width: side, height: side)
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).addClip()
            image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
            if dimmed {
                NSColor.black.withAlphaComponent(0.5).setFill()
                r.fill()
                // Znak pauzy w proporcjach dawnej miniatury 18 pt.
                let k = side / 18
                NSColor.white.setFill()
                NSBezierPath(roundedRect: NSRect(x: 5.5 * k, y: 5 * k, width: 2.5 * k, height: 8 * k), xRadius: 0.8 * k, yRadius: 0.8 * k).fill()
                NSBezierPath(roundedRect: NSRect(x: 10 * k, y: 5 * k, width: 2.5 * k, height: 8 * k), xRadius: 0.8 * k, yRadius: 0.8 * k).fill()
            }
            return true
        }
    }

    private static func clip(_ s: String, _ max: Int) -> String {
        s.count > max ? String(s.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…" : s
    }
}

/// Postep utworu jako mini fala dzwieku przy dolnej krawedzi pozycji w pasku menu, pod tekstem (od `leading` do prawej).
/// Cienkie slupki (2 pt co 3 pt, 2,5-6,5 pt wysokosci) o ksztalcie wyliczanym z tytulu i wykonawcy - TIDAL nie daje
/// prawdziwej fali. Dwa identyczne zestawy slupkow: przygaszony (labelColor, alfa 0,30 w ciemnym i 0,25 w jasnym
/// wygladzie) i pomaranczowy (systemOrange) w kontenerze przycietym do zagranej dlugosci, wiec wypelnienie przesuwa sie
/// plynnie takze przez srodek slupka. Trzy slupki przy glowicy "oddychaja" (+-50%, najwyzej 7 pt, okres 0,7 s) tylko
/// podczas gry, w obu zestawach naraz. Wszystko to animacje Core Animation (bez timera na klatke). Przezroczysta dla myszy.
final class ProgressLineView: NSView {
    static let sideInset: CGFloat = 4
    static let pitch: CGFloat = 3
    static let barWidth: CGFloat = 2
    /// Srodek slupkow nad dolna krawedzia pozycji: najwyzszy slupek (6,5 pt) i oddech do 7 pt mieszcza sie w 0...7 pt.
    static let centerY: CGFloat = 3.5
    static let minHeight: CGFloat = 2.5
    static let heightSpan: CGFloat = 4
    static let peakHeight: CGFloat = 7
    static let breathAmount: CGFloat = 0.5
    static let breathPeriod: CFTimeInterval = 0.7
    /// Skok dalej niz tyle pt (albo wstecz) to przewiniecie lub nowy utwor: wypelnienie przeskakuje bez animacji.
    static let maxAnimatedStep: CGFloat = 8

    var fraction: Double = 0 {
        didSet { if abs(fraction - oldValue) > 0.0005 { needsLayout = true } }
    }

    /// Lewy koniec slupkow (za okladka); prawy koniec stoi `sideInset` od prawej krawedzi.
    var leading: CGFloat = ProgressLineView.sideInset {
        didSet { if leading != oldValue { needsLayout = true } }
    }

    /// Tytul i wykonawca utworu: z nich wynika ksztalt fali.
    var trackKey = "" {
        didSet { if trackKey != oldValue { needsLayout = true } }
    }

    /// Oddychanie slupkow przy glowicy i plynny ruch wypelnienia tylko podczas gry (i gdy widok jest widoczny).
    var playing = false {
        didSet {
            guard playing != oldValue else { return }
            if !playing { clip.removeAnimation(forKey: "fill") }
            updateBreathing()
        }
    }

    private let dimLayer = CALayer()
    private let clip = CALayer()           // kontener zestawu pomaranczowego, przyciety do zagranej dlugosci
    private var dimBars: [CALayer] = []
    private var orangeBars: [CALayer] = []
    private var heights: [CGFloat] = []
    private var builtKey = ""
    private var builtLeading: CGFloat = -1
    private var headIndex = -1
    private var breathing: [Int: CGFloat] = [:]   // indeks slupka -> wspolczynnik oddechu
    private var lastFillUpdate: CFTimeInterval = 0
    private var orangeColor = NSColor.systemOrange.cgColor
    private var dimColor = NSColor.labelColor.withAlphaComponent(0.3).cgColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        clip.masksToBounds = true
        clip.anchorPoint = .zero
        clip.position = .zero
        layer?.addSublayer(dimLayer)
        layer?.addSublayer(clip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let w = max(0, bounds.width - leading - Self.sideInset)
        let n = Int(w / Self.pitch)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var rebuilt = false
        if n != dimBars.count || trackKey != builtKey || leading != builtLeading {
            rebuild(count: n)
            rebuilt = true
        }
        applyFill(jump: rebuilt)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        resolveColors()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for b in dimBars { b.backgroundColor = dimColor }
        for b in orangeBars { b.backgroundColor = orangeColor }
        CATransaction.commit()
    }

    /// Slupki tworzone od nowa tylko przy zmianie szerokosci, poczatku albo utworu.
    private func rebuild(count n: Int) {
        for b in dimBars + orangeBars { b.removeAllAnimations(); b.removeFromSuperlayer() }
        clip.removeAnimation(forKey: "fill")
        dimBars = []
        orangeBars = []
        breathing = [:]
        headIndex = -1
        builtKey = trackKey
        builtLeading = leading
        heights = Self.waveform(key: trackKey, count: n)
        resolveColors()
        for i in 0..<n {
            for (set, parent, color) in [(0, dimLayer, dimColor), (1, clip, orangeColor)] {
                let l = CALayer()
                l.cornerRadius = Self.barWidth / 2
                l.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: heights[i])
                l.position = CGPoint(x: leading + CGFloat(i) * Self.pitch + Self.barWidth / 2, y: Self.centerY)
                l.backgroundColor = color
                parent.addSublayer(l)
                if set == 0 { dimBars.append(l) } else { orangeBars.append(l) }
            }
        }
        updateBreathing()
    }

    /// Dlugosc zagranego odcinka: ulamek utworu na rozpietosci slupkow (od lewej krawedzi pierwszego do prawej ostatniego).
    /// Zwykly krok (do `maxAnimatedStep` pt w przod podczas gry) animuje krawedz przyciecia liniowo przez czas od
    /// poprzedniego odswiezenia, wiec wypelnienie plynie ciagle takze przez srodek slupka; przewiniecie, nowy utwor,
    /// pauza i przebudowa ustawiaja krawedz od razu.
    private func applyFill(jump: Bool) {
        let n = dimBars.count
        let span = n > 0 ? CGFloat(n - 1) * Self.pitch + Self.barWidth : 0
        let f = CGFloat(min(1, max(0, fraction)))
        let target = leading + f * span
        let now = CACurrentMediaTime()
        let old = clip.bounds.width
        if abs(target - old) > 0.001 || clip.bounds.height != bounds.height {
            clip.bounds = CGRect(x: 0, y: 0, width: target, height: bounds.height)
            let step = target - old
            if !jump && playing && step > 0 && step <= Self.maxAnimatedStep {
                let a = CABasicAnimation(keyPath: "bounds.size.width")
                a.fromValue = old
                a.toValue = target
                a.duration = min(1.0, max(0.25, now - lastFillUpdate))
                a.timingFunction = CAMediaTimingFunction(name: .linear)
                a.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
                clip.add(a, forKey: "fill")
            } else {
                clip.removeAnimation(forKey: "fill")
            }
        }
        lastFillUpdate = now
        // Slupek, w ktorym stoi glowica (i dwa sasiednie) oddycha.
        let head = n > 0 ? min(n - 1, Int(f * span / Self.pitch)) : -1
        if head != headIndex {
            headIndex = head
            updateBreathing()
        }
    }

    private func resolveColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            orangeColor = NSColor.systemOrange.cgColor
            dimColor = NSColor.labelColor.withAlphaComponent(dark ? 0.30 : 0.25).cgColor
        }
    }

    /// Trzy slupki przy glowicy (ten, w ktorym stoi glowica, i dwa sasiednie) dostaja petle Core Animation, ta sama na
    /// slupku przygaszonym i pomaranczowym (zestawy zostaja identyczne); przy pauzie, ukryciu albo przesunieciu glowicy
    /// animacje znikaja, a slupki wracaja do wysokosci z fali.
    private func updateBreathing() {
        var target: [Int: CGFloat] = [:]
        if playing && !dimBars.isEmpty && headIndex >= 0 {
            for j in max(0, headIndex - 1)...min(dimBars.count - 1, headIndex + 1) {
                target[j] = j == headIndex ? 1 : 0.6
            }
        }
        guard target != breathing else { return }
        for j in breathing.keys where target[j] == nil && j < dimBars.count {
            dimBars[j].removeAnimation(forKey: "breath")
            orangeBars[j].removeAnimation(forKey: "breath")
        }
        for (j, k) in target where breathing[j] != k && j < dimBars.count {
            let h = heights[j]
            let a = CABasicAnimation(keyPath: "bounds.size.height")
            a.fromValue = h
            a.toValue = min(Self.peakHeight, h * (1 + Self.breathAmount * k))
            a.duration = Self.breathPeriod / 2
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // faza jak w szkicu: 1,7 rad na slupek
            a.timeOffset = Self.breathPeriod * (1.7 * Double(j)).truncatingRemainder(dividingBy: 2 * Double.pi) / (2 * Double.pi)
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            a.beginTime = CACurrentMediaTime()
            dimBars[j].add(a, forKey: "breath")
            orangeBars[j].add(a, forKey: "breath")
        }
        breathing = target
    }

    /// Wysokosci slupkow: deterministyczne z tytulu i wykonawcy (FNV-1a po jednostkach UTF-16 + mulberry32),
    /// ten sam wzor co w szkicu `design/2026-10-27-progress/progress.src.html`.
    static func waveform(key: String, count n: Int) -> [CGFloat] {
        var h: UInt32 = 2166136261
        for u in key.utf16 { h ^= UInt32(u); h = h &* 16777619 }
        var state = h
        func rnd() -> Double {
            state = state &+ 0x6D2B79F5
            var t = (state ^ (state >> 15)) &* (1 | state)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4294967296
        }
        let s1 = rnd() * 6, s2 = rnd() * 6
        var out: [CGFloat] = []
        for i in 0..<n {
            let fi = Double(i)
            var v = 0.5 + 0.26 * sin(fi * 0.21 + s1) + 0.18 * sin(fi * 0.57 + s2) + 0.3 * (rnd() - 0.5)
            if i < 3 { v *= 0.6 + fi * 0.13 }
            if n - 1 - i < 3 { v *= 0.6 + Double(n - 1 - i) * 0.13 }
            v = max(0.1, min(1, v))
            out.append(CGFloat(((Double(minHeight) + Double(heightSpan) * v) * 4).rounded() / 4))
        }
        return out
    }
}
