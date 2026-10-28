import AppKit
import CryptoKit
import Network
import os

private let appLogger = Logger(subsystem: "io.github.chronosauros.tidalbar", category: "app")

/// Dziennik widoczny w log show (NSLog z dynamicznym tekstem pokazuje sie jako <private>). Bez tokenow.
func tbLog(_ message: String) { appLogger.notice("\(message, privacy: .public)") }

/// Konfiguracja logowania do TIDAL-a. Client ID i redirect URI wpisuje do Info.plist scripts/build-app.sh
/// z pliku app/tidal.local.env (poza gitem). Client ID przy PKCE nie jest sekretem, ale i tak nie trafia do repo.
enum TidalConfig {
    static let authorizeURL = URL(string: "https://login.tidal.com/authorize")!
    static let tokenURL = URL(string: "https://auth.tidal.com/v1/oauth2/token")!
    static let apiBase = "https://openapi.tidal.com/v2"

    static var clientID: String? { plistValue("TIDALClientID") }
    static var redirectURI: String { plistValue("TIDALRedirectURI") ?? "tidalbar://callback" }
    /// search.read (poziom THIRD_PARTY) sluzy do wyszukiwania numeru utworu w API, gdy TIDAL nie zapisal go w cache -
    /// a grajacy utwor zwykle go tam nie ma. Zakresy trzeba tez wlaczyc w aplikacji na developer.tidal.com;
    /// TIDAL_SCOPES w tidal.local.env nadpisuje te liste.
    static var scopes: String { plistValue("TIDALScopes") ?? "collection.read collection.write search.read" }
    static var isConfigured: Bool { clientID != nil }

    /// ~/Library/Application Support/TidalBar (0700): tokeny i zbior ulubionych. Folder, bundle ID i schemat
    /// tidalbar:// zostaja z nazwy roboczej, zeby istniejace instalacje nie tracily logowania.
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TidalBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    private static func plistValue(_ key: String) -> String? {
        let s = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }
}

enum AuthError: LocalizedError {
    case notConfigured, notLoggedIn, badRedirect, cancelled, timedOut
    case denied(String)
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "TIDAL login is not configured"
        case .notLoggedIn: return "Not logged in to TIDAL"
        case .badRedirect: return "Invalid redirect URI in configuration"
        case .cancelled: return "Login cancelled"
        case .timedOut: return "Login timed out"
        case .denied(let d): return "TIDAL refused the login: \(d)"
        case .server(let c): return "TIDAL token endpoint returned HTTP \(c)"
        }
    }
}

struct Tokens: Codable {
    var access: String
    var refresh: String?
    var expiresAt: Date
    var scope: String?
}

/// Logowanie OAuth 2.1 Authorization Code + PKCE (S256), bez client secret.
/// Tokeny leza w pliku 0600 w Application Support (nie w Keychain: aplikacja jest podpisana ad hoc,
/// wiec po kazdej przebudowie Keychain pytalby o dostep). Tokenow nie logujemy.
@MainActor
final class TidalAuth: ObservableObject {
    @Published private(set) var loggedIn = false

    private var tokens: Tokens?
    private var pending: Pending?
    private var refreshTask: Task<Tokens, Error>?
    private let file = TidalConfig.supportDir.appendingPathComponent("tokens.json")

    init() {
        if let data = try? Data(contentsOf: file), let t = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = t
            loggedIn = true
        }
    }

    var grantedScopes: String { tokens?.scope ?? "" }

    // MARK: Logowanie

    func login() async throws {
        guard let clientID = TidalConfig.clientID else { throw AuthError.notConfigured }
        guard let redirect = URL(string: TidalConfig.redirectURI), let scheme = redirect.scheme?.lowercased() else {
            throw AuthError.badRedirect
        }
        pending?.finish(.failure(AuthError.cancelled))

        let verifier = Self.randomBase64URL(32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomBase64URL(16)

        var listener: LoopbackListener?
        if scheme == "http" {
            guard redirect.host == "127.0.0.1" || redirect.host == "localhost", redirect.port != nil else {
                throw AuthError.badRedirect
            }
            listener = try LoopbackListener(port: UInt16(redirect.port!), path: redirect.path.isEmpty ? "/" : redirect.path) { [weak self] url in
                MainActor.assumeIsolated { self?.deliver(url) }
            } onFailure: { [weak self] in
                MainActor.assumeIsolated { self?.pending?.finish(.failure(AuthError.badRedirect)) }
            }
        } else if scheme != "tidalbar" {
            throw AuthError.badRedirect
        }
        defer { listener?.stop() }

        var c = URLComponents(url: TidalConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: TidalConfig.redirectURI),
            .init(name: "scope", value: TidalConfig.scopes),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        let authURL = c.url!

        let p = Pending(state: state)
        let code: String = try await withCheckedThrowingContinuation { cont in
            p.continuation = cont
            pending = p
            NSWorkspace.shared.open(authURL)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                if self?.pending === p { p.finish(.failure(AuthError.timedOut)); self?.pending = nil }
            }
        }

        let t = try await requestTokens([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("redirect_uri", TidalConfig.redirectURI),
            ("code_verifier", verifier),
        ], previous: nil)
        store(t)
    }

    /// Wywolywane z handlera tidalbar:// (kAEGetURL) albo z nasluchu na loopback.
    func deliver(_ url: URL) {
        guard let p = pending else { tbLog("bloombar: login callback ignored (no login in progress)"); return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        pending = nil
        guard v("state") == p.state else { p.finish(.failure(AuthError.denied("state mismatch"))); return }
        if let e = v("error") { p.finish(.failure(AuthError.denied(v("error_description") ?? e))); return }
        guard let code = v("code") else { p.finish(.failure(AuthError.denied("no code"))); return }
        p.finish(.success(code))
    }

    func logout() {
        pending?.finish(.failure(AuthError.cancelled))
        pending = nil
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
        loggedIn = false
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Token dostepu

    /// Zwraca wazny token; odswieza, gdy zostalo < 5 min albo na zadanie (po 401).
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let t = tokens else { throw AuthError.notLoggedIn }
        if !forceRefresh && t.expiresAt.timeIntervalSinceNow > 300 { return t.access }
        guard let refresh = t.refresh, let clientID = TidalConfig.clientID else {
            if t.expiresAt.timeIntervalSinceNow > 10 && !forceRefresh { return t.access }
            logout()
            throw AuthError.notLoggedIn
        }
        if let running = refreshTask { return try await running.value.access }
        let task = Task { () -> Tokens in
            try await self.requestTokens([
                ("grant_type", "refresh_token"),
                ("refresh_token", refresh),
                ("client_id", clientID),
            ], previous: t)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh.access
        } catch AuthError.server(let code) where code == 400 || code == 401 {
            // Refresh token odrzucony - trzeba zalogowac sie od nowa.
            logout()
            throw AuthError.notLoggedIn
        }
    }

    private func requestTokens(_ form: [(String, String)], previous: Tokens?) async throws -> Tokens {
        var req = URLRequest(url: TidalConfig.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(form)
        req.timeoutInterval = 30
        let (data, res) = try await URLSession.shared.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else { throw AuthError.server(status) }
        let expires = (obj["expires_in"] as? Double) ?? 3600
        return Tokens(access: access,
                      refresh: (obj["refresh_token"] as? String) ?? previous?.refresh,
                      expiresAt: Date().addingTimeInterval(expires),
                      scope: (obj["scope"] as? String) ?? previous?.scope)
    }

    private func store(_ t: Tokens) {
        tokens = t
        loggedIn = true
        guard let data = try? JSONEncoder().encode(t) else { return }
        // Plik powstaje od razu z 0600 (createFile ustawia tryb przy tworzeniu), potem podmiana.
        let tmp = file.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        if FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) {
            _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    // MARK: Pomocnicze

    private final class Pending {
        let state: String
        var continuation: CheckedContinuation<String, Error>?
        init(state: String) { self.state = state }
        func finish(_ r: Result<String, Error>) {
            continuation?.resume(with: r)
            continuation = nil
        }
    }

    private static func randomBase64URL(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ items: [(String, String)]) -> Data {
        let ok = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(items.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: ok)!)=\(v.addingPercentEncoding(withAllowedCharacters: ok)!)"
        }.joined(separator: "&").utf8)
    }
}

/// Jednorazowy nasluch tylko na 127.0.0.1 (redirect URI http://127.0.0.1:<port>/callback).
/// Odpowiada strona "You can close this tab", przekazuje adres dalej i konczy sie razem z logowaniem.
final class LoopbackListener {
    private let listener: NWListener
    private let path: String
    private let port: UInt16
    private let onURL: (URL) -> Void

    init(port: UInt16, path: String, onURL: @escaping (URL) -> Void, onFailure: @escaping () -> Void) throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { throw AuthError.badRedirect }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: p)
        listener = try NWListener(using: params)
        self.path = path
        self.port = port
        self.onURL = onURL
        listener.stateUpdateHandler = { state in
            if case .failed = state { onFailure() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: .main)
    }

    func stop() { listener.cancel() }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8),
                  let line = head.components(separatedBy: "\r\n").first else { conn.cancel(); return }
            let parts = line.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : "/"
            let isCallback = target == self.path || target.hasPrefix(self.path + "?")
            let body = "<!doctype html><meta charset=utf-8><title>bloombar</title>"
                + "<body style=\"font:16px -apple-system,sans-serif;text-align:center;margin-top:20vh\">"
                + "<h2>You can close this tab</h2><p>bloombar is now connected to TIDAL.</p></body>"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(isCallback ? body.utf8.count : 0)\r\nConnection: close\r\n\r\n" + (isCallback ? body : "")
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            if isCallback, let url = URL(string: "http://127.0.0.1:\(self.port)\(target)") { self.onURL(url) }
        }
    }
}
