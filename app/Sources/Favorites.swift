import AppKit

/// Klient oficjalnego API TIDAL-a v2 (JSON:API). Token dolacza i odswieza TidalAuth.
@MainActor
final class TidalAPI {
    enum APIError: LocalizedError {
        case http(Int, String?)
        var status: Int { switch self { case .http(let c, _): return c } }
        var errorDescription: String? {
            switch self {
            case .http(let c, let code): return "TIDAL API returned HTTP \(c)" + (code.map { " (\($0))" } ?? "")
            }
        }
    }

    private let auth: TidalAuth

    init(auth: TidalAuth) { self.auth = auth }

    /// Zapytanie kodowane recznie: URLComponents zostawia w wartosciach "&" i "+", a nazwy wykonawcow je maja
    /// ("Simon & Garfunkel"). Poza znakami niezarezerwowanymi zostaje tylko przecinek (lista w include).
    private static let queryAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,")

    static func encodedQuery(_ items: [URLQueryItem]) -> String {
        items.map { i in
            let k = i.name.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? i.name
            let v = (i.value ?? "").addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// Jedna ponowna proba po 401 (z odswiezeniem tokenu); 429 szanuje Retry-After (do 60 s, dwa razy).
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var refreshed = false
        var throttled = 0
        while true {
            var c = URLComponents(string: TidalConfig.apiBase + path)!
            if !query.isEmpty { c.percentEncodedQuery = Self.encodedQuery(query) }
            var req = URLRequest(url: c.url!)
            req.httpMethod = method
            req.timeoutInterval = 30
            req.setValue("Bearer \(try await auth.accessToken())", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
            if let body {
                req.httpBody = body
                req.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
                req.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
            }
            let (data, res) = try await URLSession.shared.data(for: req)
            let status = (res as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                return data
            case 401 where !refreshed:
                refreshed = true
                _ = try await auth.accessToken(forceRefresh: true)
            case 429 where throttled < 2:
                throttled += 1
                let wait = Double((res as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
                try await Task.sleep(nanoseconds: UInt64(min(max(wait, 1), 60) * 1_000_000_000))
            default:
                // Kod bledu z odpowiedzi JSON:API (np. INVALID_RESOURCE_ID) - publiczny, bez tokenow.
                let code = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                    .flatMap { ($0["errors"] as? [[String: Any]])?.first?["code"] as? String }
                throw APIError.http(status, code)
            }
        }
    }
}

/// Ulubione utwory uzytkownika. API nie ma pytania "czy ten utwor jest w kolekcji", wiec trzymamy zbior numerow
/// z kopia w Application Support. Pierwsze pobranie (cala kolekcja, 20 pozycji na strone) i codzienne pelne
/// odswiezenie ida w tle; zwykle odswiezenia (start, co 30 min, otwarcie okna co 5 min) sa przyrostowe: od
/// najnowszych, az strona zawiera juz tylko znane numery. Klik nigdy nie czeka na synchronizacje: zbior zmienia
/// sie od razu, a przy bledzie wraca.
@MainActor
final class FavoritesStore: ObservableObject {
    @Published private(set) var ids: Set<String> = []
    @Published private(set) var syncing = false
    /// Numery, dla ktorych POST/DELETE jest w drodze.
    @Published private(set) var busy: Set<String> = []
    /// Logowanie albo szukanie numeru utworu po kliknieciu - serduszko pokazuje wskaznik pracy.
    @Published private(set) var working = false
    @Published var toast: String?

    let auth: TidalAuth
    private let api: TidalAPI
    private let file = TidalConfig.supportDir.appendingPathComponent("favorites.json")
    private var lastSync: Date?
    private var lastFull: Date?
    private var changedDuringSync: [String: Bool] = [:]
    private var timer: Timer?
    private var toastTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var loginInProgress = false

    private static let fullSyncInterval: TimeInterval = 24 * 3600

    init(auth: TidalAuth) {
        self.auth = auth
        api = TidalAPI(auth: auth)
        loadFile()
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }

    // MARK: Stan

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Logowanie

    /// Zwraca true po udanym zalogowaniu. Pobranie ulubionych idzie w tle i nie jest czekane.
    @discardableResult
    func logIn() async -> Bool {
        guard TidalConfig.isConfigured else { return false }
        do {
            try await auth.login()
        } catch {
            tbLog("bloombar: login failed: \(error.localizedDescription)")
            showToast(error.localizedDescription)
            return false
        }
        tbLog("bloombar: login ok")
        refresh()
        return true
    }

    func logOut() {
        syncTask?.cancel()
        auth.logout()
        ids = []
        lastSync = nil
        lastFull = nil
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Serduszko

    /// Klik w serduszko. Zawsze daje widoczna reakcje: zmiane serduszka, wskaznik pracy albo komunikat.
    /// Niezalogowany: logowanie, a po nim dodanie utworu, ktory GRAL W CHWILI KLIKNIECIA (POST dodania jest
    /// bezpieczny takze dla utworu, ktory juz jest w kolekcji). Numer utworu bywa nieznany (nie ma go w cache
    /// TIDAL-a) - wtedy szukamy go w API, a gdy sie nie da, nie lubimy niczego (nigdy zlej wersji).
    func heartTapped(np: NowPlaying) {
        guard let track = np.track else { return }
        let known = np.trackID
        let state = known.map { ids.contains($0) ? "liked" : "not liked" } ?? "id unknown"
        tbLog("bloombar: heart tapped (\(track.artist) - \(track.title)) track=\(known ?? "?") state=\(state) loggedIn=\(auth.loggedIn) syncing=\(syncing)")
        guard TidalConfig.isConfigured else {
            showToast("TIDAL login is not configured. Add app/tidal.local.env and rebuild.")
            return
        }
        guard !working else {
            showToast(loginInProgress ? "Finish logging in to TIDAL in your browser" : "Still looking up this track")
            return
        }
        if let id = known, busy.contains(id) {
            tbLog("bloombar: heart tap ignored, update already in flight (track \(id))")
            return
        }
        Task { await handleTap(track: track, known: known, np: np) }
    }

    private func handleTap(track: Track, known: String?, np: NowPlaying) async {
        var justLoggedIn = false
        if !auth.loggedIn {
            working = true
            loginInProgress = true
            defer { working = false; loginInProgress = false }
            showToast("Log in to TIDAL in your browser to add favorites")
            guard await logIn() else { return }
            justLoggedIn = true
        }
        var id = known
        if id == nil {
            working = true
            defer { working = false }
            id = await np.resolveOnce(track)?.id
        }
        guard let id else {
            np.retryResolve()
            tbLog("bloombar: heart tap: track id not found (\(track.artist) - \(track.title))")
            showToast(justLoggedIn ? "Logged in. Track not found in TIDAL - try again in a moment"
                                   : "Couldn't find this track in TIDAL")
            return
        }
        // Po zalogowaniu dodajemy (nie przelaczamy): numer z klikniecia, nie ten, ktory gra teraz.
        await set(id, liked: justLoggedIn ? true : !ids.contains(id))
    }

    private func set(_ id: String, liked: Bool) async {
        busy.insert(id)
        defer { busy.remove(id) }
        apply(id, liked: liked)
        let verb = liked ? "POST" : "DELETE"
        tbLog("bloombar: favorite \(verb) sent (track \(id))")
        let body = try? JSONSerialization.data(withJSONObject: ["data": [["type": "tracks", "id": id]]])
        do {
            _ = try await api.send(verb, "/userCollectionTracks/me/relationships/items", body: body)
            tbLog("bloombar: favorite \(verb) ok (track \(id))")
            saveFile()
        } catch {
            tbLog("bloombar: favorite \(verb) failed (track \(id)): \(error.localizedDescription)")
            apply(id, liked: !liked)
            if !auth.loggedIn {
                showToast("Logged out of TIDAL - log in again")
            } else if let e = error as? TidalAPI.APIError {
                showToast("Couldn't update your TIDAL favorites (HTTP \(e.status))")
            } else {
                showToast("Couldn't reach TIDAL - favorite not saved")
            }
        }
    }

    private func apply(_ id: String, liked: Bool) {
        if liked { ids.insert(id) } else { ids.remove(id) }
        if syncing { changedDuringSync[id] = liked }
    }

    // MARK: Synchronizacja

    /// Przy otwarciu okna: odswieza, jesli ostatnie pobranie bylo dawniej niz 5 min temu.
    func refreshIfStale() {
        if let t = lastSync, Date().timeIntervalSince(t) < 300 { return }
        refresh()
    }

    func refresh() {
        guard auth.loggedIn, !syncing else { return }
        syncTask = Task { await sync() }
    }

    private struct BadPage: Error {}

    /// Pelne pobranie (pierwsze i najwyzej raz na dobe - usuniecia zrobione w TIDAL-u) dokleja kazda strone do
    /// zbioru na biezaco, wiec serduszko dziala na tym, co juz pobrano. Przyrostowe konczy sie na pierwszej
    /// stronie z samymi znanymi numerami.
    private func sync() async {
        guard auth.loggedIn, !syncing else { return }
        let full = ids.isEmpty || lastFull.map { Date().timeIntervalSince($0) > Self.fullSyncInterval } ?? true
        let mode = full ? "full" : "incremental"
        syncing = true
        changedDuringSync = [:]
        defer { syncing = false }
        let began = Date()
        let before = ids.count
        tbLog("bloombar: favorites sync started (\(mode), \(before) known)")
        var fetched = Set<String>()
        var cursor: String?
        var pages = 0
        do {
            repeat {
                try Task.checkCancellation()
                guard auth.loggedIn else { return }
                var q: [URLQueryItem] = [.init(name: "sort", value: "-addedAt")]
                if let cursor { q.append(.init(name: "page[cursor]", value: cursor)) }
                let data = try await api.send("GET", "/userCollectionTracks/me/relationships/items", query: q)
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BadPage() }
                var page = Set<String>()
                for item in obj["data"] as? [[String: Any]] ?? [] {
                    if item["type"] as? String == "tracks", let id = item["id"] as? String { page.insert(id) }
                }
                pages += 1
                let meta = (obj["links"] as? [String: Any])?["meta"] as? [String: Any]
                cursor = meta?["nextCursor"] as? String
                fetched.formUnion(page)
                let allKnown = page.isSubset(of: ids)
                // Numery odlubione w trakcie (changedDuringSync == false) nie wracaja ze starej strony.
                let add = page.filter { changedDuringSync[$0] != false }
                if !add.isSubset(of: ids) { ids.formUnion(add) }
                if !full && allKnown { cursor = nil }
            } while cursor != nil
        } catch {
            tbLog("bloombar: favorites sync failed after \(pages) pages (\(mode)): \(error.localizedDescription)")
            return
        }
        if full {
            var all = fetched
            for (id, liked) in changedDuringSync { if liked { all.insert(id) } else { all.remove(id) } }
            ids = all
            lastFull = Date()
        }
        lastSync = Date()
        saveFile()
        tbLog("bloombar: favorites synced (\(mode), \(pages) pages, \(ids.count) tracks, \(ids.count - before) new, \(String(format: "%.1f", Date().timeIntervalSince(began))) s)")
    }

    // MARK: Kopia na dysku

    private struct Snapshot: Codable { var ids: [String]; var synced: Date?; var full: Date? }

    private func loadFile() {
        guard auth.loggedIn, let data = try? Data(contentsOf: file),
              let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        ids = Set(s.ids)
        lastSync = s.synced
        // Starsze pliki nie mialy pola "full": kazde pobranie bylo wtedy pelne.
        lastFull = s.full ?? s.synced
    }

    private func saveFile() {
        guard let data = try? JSONEncoder().encode(Snapshot(ids: Array(ids), synced: lastSync, full: lastFull)) else { return }
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
    }

    // MARK: Zapas: wyszukiwanie w API, gdy w cache TIDAL-a nie ma utworu

    /// Wymaga zakresu search.read (TIDAL_SCOPES w tidal.local.env). `GET /searchResults?filter[query]=...`
    /// (sciezka `/searchResults/{id}/relationships/tracks` bierze identyfikator wyniku, nie tekst - dawalo 400
    /// INVALID_RESOURCE_ID). Zwraca numer tylko przy jednym pewnym trafieniu: ten sam tytul, wykonawca i czas
    /// trwania +-2 s; przy kilku zgodnych decyduje album.
    func searchTrack(_ t: Track) async -> ResolvedTrack? {
        guard auth.loggedIn, auth.grantedScopes.contains("search.read") else { return nil }
        let query = String("\(t.artist) \(t.title)".prefix(256))
        let country = Locale.current.region?.identifier ?? "US"
        let data: Data
        do {
            data = try await api.send("GET", "/searchResults", query: [
                .init(name: "filter[query]", value: query),
                .init(name: "countryCode", value: country),
                .init(name: "include", value: "tracks,tracks.artists,tracks.albums"),
            ])
        } catch {
            tbLog("bloombar: track search failed: \(error.localizedDescription)")
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let included = obj["included"] as? [[String: Any]] ?? []
        var artistNames: [String: String] = [:]
        var albumTitles: [String: String] = [:]
        for r in included {
            guard let id = r["id"] as? String, let n = (r["attributes"] as? [String: Any]) else { continue }
            if r["type"] as? String == "artists", let name = n["name"] as? String { artistNames[id] = name }
            if r["type"] as? String == "albums", let title = n["title"] as? String { albumTitles[id] = title }
        }
        let wantTitle = TrackResolver.normalize(t.title)
        let wantArtist = TrackResolver.normalize(t.artist)
        let wantAlbum = TrackResolver.normalize(t.album)
        var hits: [(track: ResolvedTrack, album: Bool)] = []
        for r in included where r["type"] as? String == "tracks" {
            guard let id = r["id"] as? String, let a = r["attributes"] as? [String: Any],
                  let title = a["title"] as? String,
                  let dur = Self.isoSeconds(a["duration"] as? String), abs(dur - t.duration) <= 2 else { continue }
            let version = a["version"] as? String
            let titles = [title] + (version.map { ["\(title) (\($0))", "\(title) - \($0)"] } ?? [])
            guard titles.contains(where: { TrackResolver.normalize($0) == wantTitle }) else { continue }
            let rels = r["relationships"] as? [String: Any]
            let refs = (rels?["artists"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            let names = refs.compactMap { ($0["id"] as? String).flatMap { artistNames[$0] } }
            guard names.contains(where: { n in
                let nn = TrackResolver.normalize(n)
                return !nn.isEmpty && !wantArtist.isEmpty && (wantArtist.contains(nn) || nn.contains(wantArtist))
            }) else { continue }
            let albumRefs = (rels?["albums"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            let albumMatch = !wantAlbum.isEmpty && albumRefs.contains { ref in
                (ref["id"] as? String).flatMap { albumTitles[$0] }.map(TrackResolver.normalize) == wantAlbum
            }
            hits.append((ResolvedTrack(id: id, bpm: (a["bpm"] as? NSNumber)?.doubleValue, source: "api-search"), albumMatch))
        }
        var cands = hits
        if Set(cands.map(\.track.id)).count > 1, cands.contains(where: \.album) { cands = cands.filter(\.album) }
        return Set(cands.map(\.track.id)).count == 1 ? cands.first?.track : nil
    }

    private static func isoSeconds(_ s: String?) -> Double? {
        guard let s, s.hasPrefix("PT") else { return nil }
        var total = 0.0
        var num = ""
        for ch in s.dropFirst(2) {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard let v = Double(num) else { return nil }
            switch ch {
            case "H": total += v * 3600
            case "M": total += v * 60
            case "S": total += v
            default: return nil
            }
            num = ""
        }
        return total
    }
}
