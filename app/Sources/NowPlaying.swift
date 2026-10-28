import AppKit
import Combine

/// Proces mediaremote-adapter uruchamiany przez systemowy perl - tylko on dostaje od macOS dane "Teraz odtwarzane".
struct Adapter {
    let script: URL
    let framework: URL

    static func bundled() -> Adapter? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("adapter") else { return nil }
        let a = Adapter(script: res.appendingPathComponent("mediaremote-adapter.pl"),
                        framework: res.appendingPathComponent("MediaRemoteAdapter.framework"))
        return FileManager.default.fileExists(atPath: a.script.path) ? a : nil
    }

    func process(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path] + args
        return p
    }
}

struct Track: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double
}

@MainActor
final class NowPlaying: ObservableObject {
    static let tidalBundleID = "com.tidal.desktop"

    @Published private(set) var track: Track?
    @Published private(set) var playing = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: NSColor = .white
    /// Numer utworu w TIDAL-u i BPM (z cache TIDAL-a, zapas: wyszukiwanie w API). nil = nieznany.
    @Published private(set) var trackID: String?
    @Published private(set) var bpm: Double?
    /// Zapas, gdy w cache nic nie ma (ustawia AppDelegate; wymaga zalogowania).
    var searchFallback: (@MainActor (Track) async -> ResolvedTrack?)?

    private let resolver = TrackResolver()
    private var resolveTask: Task<Void, Never>?

    private var elapsedAtStamp: Double = 0
    private var stamp = Date()
    private var rate: Double = 1
    private var artworkKey: String?
    private var process: Process?
    private var buffer = Data()
    private let adapter: Adapter
    private let artworkStore = ArtworkStore()

    init(adapter: Adapter) {
        self.adapter = adapter
    }

    // MARK: Czas

    func elapsed(at date: Date = Date()) -> Double {
        guard let track else { return 0 }
        var e = elapsedAtStamp
        if playing { e += date.timeIntervalSince(stamp) * (rate > 0 ? rate : 1) }
        return track.duration > 0 ? min(max(0, e), track.duration) : max(0, e)
    }

    func fraction(at date: Date = Date()) -> Double {
        guard let d = track?.duration, d > 0 else { return 0 }
        return elapsed(at: date) / d
    }

    // MARK: Strumien z adaptera

    func start() {
        let p = adapter.process(["stream", "--no-diff", "--debounce=100",
                                 "--experimental-peculiar-debounce:\(Self.tidalBundleID)=1000"])
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(chunk) } }
        }
        p.terminationHandler = { [weak self] _ in
            // Adapter padl (np. po aktualizacji systemu) - wstajemy ponownie po chwili.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self?.start() } }
        }
        do {
            try p.run()
            process = p
        } catch {
            NSLog("bloombar: adapter failed to start: \(error)")
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            handle(line)
        }
    }

    private func handle(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "data",
              let p = obj["payload"] as? [String: Any] else { return }
        let bundle = p["bundleIdentifier"] as? String

        guard let title = p["title"] as? String, let bundle else {
            // Nic nie gra albo TIDAL zostal zamkniety.
            if bundle == nil || bundle == Self.tidalBundleID { clear() }
            return
        }
        // Inne odtwarzacze (np. Safari) pomijamy - zostaje ostatni stan TIDAL-a.
        guard bundle == Self.tidalBundleID else { return }

        let t = Track(title: title,
                      artist: p["artist"] as? String ?? "",
                      album: p["album"] as? String ?? "",
                      duration: p["duration"] as? Double ?? 0)
        if t != track {
            track = t
            resolve(t)
        }
        playing = p["playing"] as? Bool ?? false
        rate = p["playbackRate"] as? Double ?? 1
        elapsedAtStamp = p["elapsedTime"] as? Double ?? 0
        stamp = (p["timestamp"] as? String).flatMap(Self.parseDate) ?? Date()

        var small: NSImage?
        if let b64 = p["artworkData"] as? String, let d = Data(base64Encoded: b64) { small = NSImage(data: d) }
        let key = "\(t.artist)|\(t.album)"
        if key != artworkKey {
            artworkKey = key
            setArtwork(small)
            loadHiRes(for: t, key: key)
        } else if artwork == nil, let small {
            setArtwork(small)
        }
    }

    /// Szuka numeru utworu: od razu, a gdy go jeszcze nie ma - ponawia po 3, 8 i 20 s. TIDAL zapisuje utwor do
    /// cache dopiero po chwili, wiec dwie pierwsze proby (0 i 3 s) pytaja tylko cache; wyszukiwanie w API
    /// (po zalogowaniu, z zakresem search.read) dochodzi dopiero od trzeciej proby (ok. 11 s).
    private func resolve(_ t: Track) {
        resolveTask?.cancel()
        trackID = nil
        bpm = nil
        resolveTask = Task { [weak self] in
            for (n, d) in ([0, 3, 8, 20] as [UInt64]).enumerated() {
                if d > 0 { try? await Task.sleep(nanoseconds: d * 1_000_000_000) }
                guard !Task.isCancelled, let self else { return }
                if await self.resolveOnce(t, useAPI: n >= 2) != nil { return }
            }
            guard !Task.isCancelled else { return }
            tbLog("bloombar: track id not found (\(t.artist) - \(t.title))")
        }
    }

    /// Jedna proba: cache TIDAL-a, a przy `useAPI` takze zapas przez API. Zwraca wynik dla podanego utworu,
    /// ale trackID i bpm ustawia tylko, gdy to nadal grajacy utwor (klik w serduszko moze dotyczyc poprzedniego).
    @discardableResult
    func resolveOnce(_ t: Track, useAPI: Bool = true) async -> ResolvedTrack? {
        var r = await resolver.lookup(t)
        if r == nil, useAPI, let f = searchFallback { r = await f(t) }
        guard let r else { return nil }
        if track == t {
            trackID = r.id
            bpm = r.bpm
        }
        let bpmText = r.bpm.map { String(format: "%.1f", $0) } ?? "null"
        tbLog("bloombar: track id=\(r.id) bpm=\(bpmText) source=\(r.source) (\(t.artist) - \(t.title))")
        return r
    }

    /// Po zalogowaniu (zapas przez API stal sie dostepny) ponawia szukanie dla grajacego utworu.
    func retryResolve() {
        if let t = track, trackID == nil { resolve(t) }
    }

    private func clear() {
        resolveTask?.cancel()
        trackID = nil
        bpm = nil
        track = nil
        playing = false
        artwork = nil
        artworkKey = nil
    }

    private func setArtwork(_ image: NSImage?) {
        artwork = image
        accent = image.map(Palette.accent) ?? .white
    }

    /// Okladka z systemu ma 150 px, wiec dociagamy 1280 px z serwera TIDAL-a (albo z iTunes).
    private func loadHiRes(for t: Track, key: String) {
        Task {
            guard let data = await artworkStore.hiRes(title: t.title, artist: t.artist, album: t.album),
                  key == artworkKey, let image = NSImage(data: data) else { return }
            setArtwork(image)
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    // MARK: Sterowanie

    func togglePlayPause() {
        elapsedAtStamp = elapsed()
        stamp = Date()
        playing.toggle()
        run(["send", "2"])
    }

    func next() { run(["send", "4"]) }

    func previous() { run(["send", "5"]) }

    func seek(to seconds: Double) {
        elapsedAtStamp = seconds
        stamp = Date()
        objectWillChange.send()
        run(["seek", String(Int(seconds * 1_000_000))])
    }

    private func run(_ args: [String]) {
        let p = adapter.process(args)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
