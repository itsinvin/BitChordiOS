import Foundation
import JavaScriptCore
import CommonCrypto

// MARK: - Pluggable sources (port of data/sources/*)
// Order matters: user-added sources are consulted before YouTube Music,
// exactly like SourceRegistry.active() in the original. YouTube Music is
// built-in and cannot be removed. A source that fails health-check or
// returns nothing simply falls through — never an error screen for a
// source the user did not pick.

public enum SourceKind: String, Codable, CaseIterable {
    case youtube, jiosaavn, addon, module, webdav
    public var label: String {
        switch self { case .youtube: return "YouTube Music"; case .jiosaavn: return "JioSaavn"; case .addon: return "Addon"; case .module: return "Module source"; case .webdav: return "WebDAV" }
    }
    public var canServeLossless: Bool { self == .addon || self == .module }
    public var needsServer: Bool { self == .addon || self == .module || self == .webdav }
}

public struct SourceConfig: Codable, Equatable, Identifiable {
    public var id: String; public var kind: SourceKind; public var name: String; public var serverURL: String; public var enabled: Bool
    public init(id: String = UUID().uuidString, kind: SourceKind, name: String, serverURL: String = "", enabled: Bool = true) {
        self.id = id; self.kind = kind; self.name = name; self.serverURL = serverURL; self.enabled = enabled
    }
}

public protocol SourceSearching {
    func search(query: String) async -> [Track]
    func streamURL(for track: Track) async -> StreamFormat?
    func healthCheck() async -> Bool
}

@MainActor
public final class SourceRegistry: ObservableObject {
    public static let shared = SourceRegistry()
    @Published public var sources: [SourceConfig] = [] {
        didSet { save() }
    }
    private init() {
        if let data = UserDefaults.standard.data(forKey: "sourceRegistry"),
           let decoded = try? JSONDecoder().decode([SourceConfig].self, from: data) {
            sources = decoded
        }
        if !sources.contains(where: { $0.kind == .youtube }) {
            sources.append(SourceConfig(id: "youtube", kind: .youtube, name: "YouTube Music"))
        }
        if !sources.contains(where: { $0.kind == .jiosaavn }) {
            sources.append(SourceConfig(id: "jiosaavn", kind: .jiosaavn, name: "JioSaavn", enabled: false))
        }
    }
    private func save() { try? UserDefaults.standard.set(JSONEncoder().encode(sources), forKey: "sourceRegistry") }
    public func add(_ config: SourceConfig) { sources.append(config) }
    public func remove(id: String) {
        guard sources.first(where: { $0.id == id })?.kind != .youtube else { return }
        sources.removeAll { $0.id == id }
    }
    public func move(from: IndexSet, to: Int) {
        var items = sources
        let moving = from.map { items[$0] }
        for idx in from.sorted(by: >) { items.remove(at: idx) }
        var dest = to
        for idx in from where idx < to { dest -= 1 }
        dest = max(0, min(dest, items.count))
        items.insert(contentsOf: moving, at: dest)
        sources = items
    }

    /// Resolve a track through sources in order, YouTube last. Returns the
    /// first stream found, or nil so the caller falls back to StreamResolver.
    public func resolve(track: Track) async -> StreamFormat? {
        for config in sources where config.enabled {
            switch config.kind {
            case .jiosaavn:
                if let format = await JioSaavnSource.shared.streamURL(for: track) { return format }
            case .addon:
                if let format = await AddonSource(config: config).streamURL(for: track) { return format }
            case .module:
                if let format = await ModuleSource(config: config).streamURL(for: track) { return format }
            case .webdav:
                if let format = await WebDAVSource(config: config).streamURL(for: track) { return format }
            case .youtube:
                break // handled by StreamResolver after this loop
            }
        }
        return nil
    }
    public func searchAll(query: String) async -> [Track] {
        var out: [Track] = []
        for config in sources where config.enabled {
            switch config.kind {
            case .jiosaavn: out += await JioSaavnSource.shared.search(query: query)
            case .addon: out += await AddonSource(config: config).search(query: query)
            case .module: out += await ModuleSource(config: config).search(query: query)
            case .webdav: out += await WebDAVSource(config: config).search(query: query)
            case .youtube: break
            }
        }
        return out
    }
}

// MARK: JioSaavn (port of data/jiosaavn/JioSaavnService.kt)

public final class JioSaavnSource: SourceSearching {
    public static let shared = JioSaavnSource()
    private let base = "https://www.jiosaavn.com/api.php"
    private init() {}
    private func get(_ params: [String: String]) async -> JSONValue? {
        var comps = URLComponents(string: base)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("explicit_content=1", forHTTPHeaderField: "Cookie")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONValue.parse(data)
    }
    /// DES/ECB/PKCS5 with the original's key "38346591".
    public static func decryptURL(_ encrypted: String) -> String {
        guard let data = Data(base64Encoded: encrypted) else { return "" }
        var out = Data(count: data.count + kCCBlockSizeDES)
        var outLength = 0
        let key = "38346591".data(using: .utf8)!
        let status = key.withUnsafeBytes { keyPtr in
            data.withUnsafeBytes { dataPtr in
                out.withUnsafeMutableBytes { outPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, kCCKeySizeDES, nil,
                            dataPtr.baseAddress, data.count, outPtr.baseAddress, out.count, &outLength)
                }
            }
        }
        guard status == kCCSuccess else { return "" }
        out.count = outLength
        return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    public static func bestStream(decryptedURL: String, supports320: Bool) -> StreamFormat? {
        guard !decryptedURL.isEmpty else { return nil }
        // Original rule: rewrite _96/_160 to _320 ONLY when the catalogue
        // says a 320 rendition exists; otherwise report the real bitrate.
        let pattern = #"_(48|96|160|320)\.(mp4|aac|mp3)(?=[?#]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: decryptedURL, range: NSRange(decryptedURL.startIndex..., in: decryptedURL)) else {
            return StreamFormat(url: decryptedURL, mimeType: "audio/mp4", bitrate: 0, codec: "JioSaavn")
        }
        let offered = Int((decryptedURL as NSString).substring(with: match.range(at: 1))) ?? 0
        if supports320, offered != 320 {
            let ext = (decryptedURL as NSString).substring(with: match.range(at: 2))
            let replaced = (decryptedURL as NSString).replacingCharacters(in: match.range, with: "_320.\(ext)")
            return StreamFormat(url: replaced, mimeType: "audio/mp4", bitrate: 320_000, codec: "JioSaavn 320")
        }
        return StreamFormat(url: decryptedURL, mimeType: "audio/mp4", bitrate: offered * 1000, codec: "JioSaavn")
    }
    public func search(query: String) async -> [Track] {
        guard let json = await get(["__call": "search.getResults", "_format": "json", "_marker": "0", "api_version": "4", "ctx": "android", "q": query, "p": "1", "n": "10"]) else { return [] }
        return (json["results"].array ?? []).compactMap { item in
            guard let id = item["id"].string, let title = item["title"].string else { return nil }
            let artists = (item["more_info"]["artistMap"]["primary_artists"].array ?? []).compactMap { $0["name"].string }
            return Track(id: "saavn:\(id)", title: title.htmlUnescaped(), artists: artists, album: item["more_info"]["album"].string, durationSeconds: Double(item["more_info"]["duration"].string ?? "") ?? 0, source: "jiosaavn")
        }
    }
    public func streamURL(for track: Track) async -> StreamFormat? {
        let saavnId = track.id.hasPrefix("saavn:") ? String(track.id.dropFirst(6)) : nil
        guard let id = saavnId ?? track.id as String? else { return nil }
        // Matching is by title/artist when the track came from YouTube: ask
        // JioSaavn for the same song and take the first result.
        let lookupId: String
        if saavnId != nil { lookupId = id } else {
            let results = await search(query: "\(track.title) \(track.artistText)")
            guard let first = results.first else { return nil }
            lookupId = String(first.id.dropFirst(6))
        }
        guard let json = await get(["__call": "song.getDetails", "_format": "json", "_marker": "0", "api_version": "4", "ctx": "android", "pids": lookupId]) else { return nil }
        let song = (json["songs"].array?.first) ?? json.object?.values.first { !$0.isNull } ?? .null
        let encrypted = song["more_info"]["encrypted_media_url"].string ?? ""
        let supports320 = (song["more_info"]["320kbps"].string ?? "") == "true"
        return Self.bestStream(decryptedURL: Self.decryptURL(encrypted), supports320: supports320)
    }
    public func healthCheck() async -> Bool {
        (await get(["__call": "search.getResults", "_format": "json", "_marker": "0", "api_version": "4", "ctx": "android", "q": "test", "p": "1", "n": "1"])) != nil
    }
}

// MARK: Addon server (plain HTTP: /manifest.json, /search, /stream)

public struct AddonSource: SourceSearching {
    public var config: SourceConfig
    public init(config: SourceConfig) { self.config = config }
    private func base() -> String { config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    public func search(query: String) async -> [Track] {
        guard let url = URL(string: "\(base())/search?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONValue.parse(data) else { return [] }
        let items = json["results"].array ?? json["tracks"].array ?? json.array ?? []
        return items.compactMap { item in
            guard let id = item["id"].string ?? item["videoId"].string, let title = item["title"].string else { return nil }
            return Track(id: id, title: title, artists: (item["artists"].array ?? []).compactMap { $0.string } + (item["artist"].string.map { [$0] } ?? []), album: item["album"].string, durationSeconds: item["duration"].double ?? 0, source: "addon")
        }
    }
    public func streamURL(for track: Track) async -> StreamFormat? {
        guard let url = URL(string: "\(base())/stream?id=\(track.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? track.id)"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONValue.parse(data),
              let stream = json["url"].string ?? json["streamUrl"].string else { return nil }
        return StreamFormat(url: stream, mimeType: json["mimeType"].string ?? "audio/flac", bitrate: json["bitrate"].int ?? 0, sampleRate: json["sampleRate"].int, codec: json["codec"].string ?? "FLAC")
    }
    public func healthCheck() async -> Bool {
        guard let url = URL(string: "\(base())/manifest.json"),
              let (_, resp) = try? await URLSession.shared.data(from: url) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

// MARK: Module source (JS plugins in a JavaScriptCore sandbox, like QuickJS on Android)

public struct ModuleSource: SourceSearching {
    public var config: SourceConfig
    public init(config: SourceConfig) { self.config = config }
    /// The JS plugin may ONLY call the wired-in fetch() and the two exported
    /// functions; it has no access to Swift objects, the filesystem, or the
    /// network except through that fetch bridge.
    private func runPlugin(_ js: String, function: String, args: [String]) -> JSONValue? {
        guard let ctx = JSContext() else { return nil }
        ctx.exceptionHandler = { _, _ in }
        let fetch: @convention(block) (String, @escaping (String) -> Void) -> Void = { urlString, callback in
            guard let url = URL(string: urlString) else { callback(""); return }
            Task {
                let text = (try? await URLSession.shared.data(from: url)).flatMap { String(data: $0.0, encoding: .utf8) } ?? ""
                callback(text)
            }
        }
        ctx.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
        ctx.evaluateScript(js)
        let result = ctx.objectForKeyedSubscript(function)?.call(withArguments: args)
        guard let jsonString = result?.toString(), !jsonString.isEmpty, jsonString != "undefined" else { return nil }
        return try? JSONValue.parse(Data(jsonString.utf8))
    }
    private func loadPlugins() async -> [(name: String, js: String)] {
        guard let url = URL(string: config.serverURL),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONValue.parse(data) else { return [] }
        var out: [(String, String)] = []
        for plugin in json["plugins"].array ?? json.array ?? [] {
            guard let name = plugin["name"].string, let jsURL = plugin["url"].string ?? plugin["jsUrl"].string,
                  let jsDataURL = URL(string: jsURL),
                  let (jsData, _) = try? await URLSession.shared.data(from: jsDataURL),
                  let js = String(data: jsData, encoding: .utf8) else { continue }
            out.append((name, js))
        }
        return out
    }
    public func search(query: String) async -> [Track] {
        var out: [Track] = []
        for plugin in await loadPlugins() {
            guard let json = runPlugin(plugin.js, function: "searchTracks", args: [query]) else { continue }
            for item in json.array ?? json["tracks"].array ?? [] {
                guard let id = item["id"].string, let title = item["title"].string else { continue }
                out.append(Track(id: id, title: title, artists: (item["artists"].array ?? []).compactMap { $0.string }, album: item["album"].string, durationSeconds: item["duration"].double ?? 0, source: "module"))
            }
        }
        return out
    }
    public func streamURL(for track: Track) async -> StreamFormat? {
        for plugin in await loadPlugins() {
            guard let json = runPlugin(plugin.js, function: "getTrackStreamUrl", args: [track.id]),
                  let url = json["url"].string ?? json.string else { continue }
            return StreamFormat(url: url, mimeType: json["mimeType"].string ?? "audio/flac", bitrate: json["bitrate"].int ?? 0, codec: "Module FLAC")
        }
        return nil
    }
    public func healthCheck() async -> Bool { !(await loadPlugins()).isEmpty }
}

// MARK: WebDAV (PROPFIND / GET / PUT, port of data/webdav/*)

public struct WebDAVSource: SourceSearching {
    public var config: SourceConfig
    public init(config: SourceConfig) { self.config = config }
    private var username: String { UserDefaults.standard.string(forKey: "webdavUsername") ?? "" }
    private var password: String { get { Keychain.get("webdavPassword") ?? "" } set { Keychain.set(newValue, for: "webdavPassword") } }
    private func request(_ url: URL, method: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url); req.httpMethod = method
        if !username.isEmpty {
            let creds = "\(username):\(password)".data(using: .utf8)!.base64EncodedString()
            req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }
    public func search(query: String) async -> [Track] {
        guard let url = URL(string: config.serverURL) else { return [] }
        let propfind = "<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><displayname/></prop></propfind>".data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: request(url, method: "PROPFIND", body: propfind)),
              (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400,
              let xml = String(data: data, encoding: .utf8) else { return [] }
        // Minimal href extraction; a full XML parser is overkill for a listing.
        var out: [Track] = []
        let regex = try? NSRegularExpression(pattern: "<[^>]*href>([^<]+)</[^>]*href>", options: .caseInsensitive)
        let ns = xml as NSString
        for m in regex?.matches(in: xml, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let href = ns.substring(with: m.range(at: 1))
            let name = href.components(separatedBy: "/").last ?? ""
            guard !name.isEmpty, ["mp3", "m4a", "flac", "wav", "opus"].contains((name as NSString).pathExtension.lowercased()),
                  name.localizedCaseInsensitiveContains(query) else { continue }
            let full = href.hasPrefix("http") ? href : config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            out.append(Track(id: "webdav:\(href)", title: (name as NSString).deletingPathExtension, artists: [], durationSeconds: 0, source: "webdav", localURL: nil))
            // The stream URL is the file URL itself; stash it in the id's
            // companion by returning a track whose id encodes the URL is
            // fragile, so streamURL() re-derives it from the same href.
            _ = full
        }
        return out
    }
    public func streamURL(for track: Track) async -> StreamFormat? {
        guard track.id.hasPrefix("webdav:") else { return nil }
        let href = String(track.id.dropFirst(7))
        let full = href.hasPrefix("http") ? href : config.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + href.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return StreamFormat(url: full, mimeType: "audio/mpeg", bitrate: 0, codec: "WebDAV")
    }
    public func healthCheck() async -> Bool {
        guard let url = URL(string: config.serverURL),
              let (_, resp) = try? await URLSession.shared.data(for: request(url, method: "PROPFIND", body: "<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><displayname/></prop></propfind>".data(using: .utf8))) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400
    }
}
