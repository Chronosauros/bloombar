import Foundation

/// Numer utworu w TIDAL-u (do ulubionych) i BPM (na pozniej, dla maskotki).
struct ResolvedTrack: Equatable {
    var id: String
    var bpm: Double?
    var source: String
}

/// Szuka obiektu utworu (id, title, artists, duration, bpm) w odpowiedziach API zapisanych w cache TIDAL-a -
/// tak samo jak ArtworkStore szuka okladki. Czytamy tylko publiczne metadane utworow.
/// Dopasowanie: tytul + wykonawca + czas trwania +-2 s. Wiele roznych numerow = niepewne, wtedy nic nie zwracamy
/// (serduszko zostaje nieaktywne, zamiast polubienia zlej wersji).
actor TrackResolver {
    private var memo: [String: ResolvedTrack] = [:]

    func lookup(_ t: Track) -> ResolvedTrack? {
        let key = "\(t.artist)|\(t.album)|\(t.title)|\(Int(t.duration))"
        if let hit = memo[key] { return hit }
        guard let r = scanCache(t) else { return nil }
        memo[key] = r
        return r
    }

    private func scanCache(_ t: Track) -> ResolvedTrack? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TIDAL/Cache/Cache_Data")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let modified: (URL) -> Date = {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        // Igla: poczatek tytulu bez zamykajacego cudzyslowu, bo wersja moze byc osobnym polem ("version").
        let needle = Data("\"title\":\"\(Self.jsonEscaped(Self.baseTitle(t.title)))".utf8)
        let wantTitle = Self.normalize(t.title)
        let wantArtist = Self.normalize(t.artist)
        let wantAlbum = Self.normalize(t.album)

        for file in files.sorted(by: { modified($0) > modified($1) }) {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  data.range(of: needle) != nil,
                  let json = Self.parseBody(data) else { continue }
            var found: [(id: String, diff: Double, album: Bool, bpm: Double?)] = []
            Self.walk(json) { d in
                guard let rawID = d["id"], let title = d["title"] as? String,
                      let dur = (d["duration"] as? NSNumber)?.doubleValue,
                      let artists = d["artists"] as? [[String: Any]] else { return }
                let version = d["version"] as? String
                let titles = [title] + (version.map { ["\(title) (\($0))", "\(title) - \($0)"] } ?? [])
                guard titles.contains(where: { Self.normalize($0) == wantTitle }) else { return }
                let diff = abs(dur - t.duration)
                guard diff <= 2 else { return }
                var names = artists.compactMap { $0["name"] as? String }
                if let main = (d["artist"] as? [String: Any])?["name"] as? String { names.append(main) }
                guard names.contains(where: { n in
                    let nn = Self.normalize(n)
                    return !nn.isEmpty && !wantArtist.isEmpty && (wantArtist.contains(nn) || nn.contains(wantArtist))
                }) else { return }
                let albumTitle = ((d["album"] as? [String: Any])?["title"] as? String).map(Self.normalize)
                found.append((Self.idString(rawID), diff, albumTitle != nil && albumTitle == wantAlbum,
                              (d["bpm"] as? NSNumber)?.doubleValue))
            }
            guard !found.isEmpty else { continue }
            // Pierwszy (najnowszy) plik z kandydatami rozstrzyga.
            var cands = found
            if cands.contains(where: { $0.album }) { cands = cands.filter { $0.album } }
            let ids = Set(cands.map { $0.id })
            var pick = cands.first!
            if ids.count > 1 {
                let sorted = cands.sorted { $0.diff < $1.diff }
                guard sorted[0].id != sorted[1].id, sorted[1].diff - sorted[0].diff > 0.5 else { return nil }
                pick = sorted[0]
            }
            // BPM bywa null w jednym obiekcie, a podany w innym tego samego utworu.
            let bpm = cands.first(where: { $0.id == pick.id && $0.bpm != nil })?.bpm
            return ResolvedTrack(id: pick.id, bpm: bpm, source: "cache")
        }
        return nil
    }

    // MARK: Pomocnicze

    private static func idString(_ v: Any) -> String {
        if let n = v as? NSNumber { return n.stringValue }
        return "\(v)"
    }

    /// Tytul bez koncowego "(...)" - wersje (Remastered, Instrumental) bywaja w polu version.
    private static func baseTitle(_ s: String) -> String {
        if let r = s.range(of: " (", options: .backwards), s.hasSuffix(")") { return String(s[..<r.lowerBound]) }
        return s
    }

    private static func walk(_ node: Any, _ visit: ([String: Any]) -> Void) {
        if let d = node as? [String: Any] {
            visit(d)
            for v in d.values { walk(v, visit) }
        } else if let a = node as? [Any] {
            for v in a { walk(v, visit) }
        }
    }

    /// Plik cache to naglowek + JSON + metadane (z klamrami). Szukamy konca pierwszego obiektu liczac nawiasy
    /// z pominieciem lancuchow, a dopiero ten kawalek parsujemy.
    private static func parseBody(_ data: Data) -> Any? {
        guard let start = data.firstIndex(of: 0x7B) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var end: Data.Index?
        var i = start
        while i < data.endIndex {
            let c = data[i]
            if inString {
                if escaped { escaped = false } else if c == 0x5C { escaped = true } else if c == 0x22 { inString = false }
            } else if c == 0x22 {
                inString = true
            } else if c == 0x7B {
                depth += 1
            } else if c == 0x7D {
                depth -= 1
                if depth == 0 { end = i; break }
            }
            i = data.index(after: i)
        }
        guard let end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(data[start...end]))
    }

    private static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
