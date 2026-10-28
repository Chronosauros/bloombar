import AppKit

/// Szuka okladki w wysokiej rozdzielczosci: najpierw ta sama okladka z serwera TIDAL-a
/// (identyfikator z pamieci podrecznej aplikacji TIDAL), potem iTunes Search API.
actor ArtworkStore {
    private var cache: [String: Data] = [:]
    private let session = URLSession(configuration: .ephemeral)

    func hiRes(title: String, artist: String, album: String) async -> Data? {
        let key = "\(artist)|\(album)"
        if let hit = cache[key] { return hit }
        var data: Data?
        if let cover = tidalCoverID(title: title, album: album) {
            let path = cover.replacingOccurrences(of: "-", with: "/")
            data = await download(URL(string: "https://resources.tidal.com/images/\(path)/1280x1280.jpg"))
        }
        if data == nil {
            data = await download(await itunesArtworkURL(artist: artist, album: album))
        }
        if let data { cache[key] = data }
        return data
    }

    /// Odpowiedzi API TIDAL-a w cache Chromium zawieraja utwor z polem album.cover (UUID okladki).
    private func tidalCoverID(title: String, album: String) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TIDAL/Cache/Cache_Data")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let modified: (URL) -> Date = {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let titleNeedle = Data("\"title\":\"\(Self.jsonEscaped(title))\"".utf8)
        let albumNeedle = Data("\"title\":\"\(Self.jsonEscaped(album))\"".utf8)
        let coverKey = Data("\"cover\":\"".utf8)

        for file in files.sorted(by: { modified($0) > modified($1) }) {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  data.range(of: titleNeedle) != nil else { continue }
            var from = data.startIndex
            while let r = data.range(of: titleNeedle, in: from..<data.endIndex) {
                let end = min(data.endIndex, r.upperBound + 6000)
                if let a = data.range(of: albumNeedle, in: r.upperBound..<end),
                   let c = data.range(of: coverKey, in: a.upperBound..<end),
                   c.upperBound + 36 <= data.endIndex {
                    let id = String(decoding: data[c.upperBound..<(c.upperBound + 36)], as: UTF8.self)
                    if id.range(of: "^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", options: .regularExpression) != nil {
                        return id
                    }
                }
                from = r.upperBound
            }
        }
        return nil
    }

    private func itunesArtworkURL(artist: String, album: String) async -> URL? {
        var c = URLComponents(string: "https://itunes.apple.com/search")!
        c.queryItems = [.init(name: "term", value: "\(artist) \(album)"),
                        .init(name: "entity", value: "album"),
                        .init(name: "limit", value: "10")]
        guard let url = c.url,
              let res = try? await session.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: res.0) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return nil }
        let wantAlbum = Self.normalize(album)
        let wantArtist = Self.normalize(artist.components(separatedBy: ",").first ?? artist)
        let match = results.first {
            Self.normalize($0["collectionName"] as? String ?? "") == wantAlbum
                && Self.normalize($0["artistName"] as? String ?? "").contains(wantArtist)
        }
        guard let small = match?["artworkUrl100"] as? String else { return nil }
        return URL(string: small.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
    }

    private func download(_ url: URL?) async -> Data? {
        guard let url, let res = try? await session.data(from: url),
              (res.1 as? HTTPURLResponse)?.statusCode == 200,
              NSImage(data: res.0) != nil else { return nil }
        return res.0
    }

    private static func jsonEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func normalize(_ s: String) -> String {
        var t = s.lowercased()
        for suffix in [" - single", " - ep"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

enum Palette {
    /// Kolor akcentu z okladki: najbardziej nasycony piksel o sredniej jasnosci.
    static func accent(of image: NSImage) -> NSColor {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        let n = 40
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return .white }
        var best = (1.0, 1.0, 1.0)
        var score = -1.0
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx > 0 ? (mx - mn) / mx : 0
            let s = sat * (1 - abs((mx + mn) / 2 - 0.55) * 1.8)
            if s > score { score = s; best = (r, g, b) }
        }
        return NSColor(srgbRed: best.0, green: best.1, blue: best.2, alpha: 1)
    }
}
