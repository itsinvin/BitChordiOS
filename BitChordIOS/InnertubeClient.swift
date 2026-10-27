import Foundation

// MARK: - Innertube client (port of shared Innertube.kt)
// WEB_REMIX (client 67) against music.youtube.com. Stream URLs are NOT fetched
// here for playback decisions; see StreamResolver.swift.

public final class InnertubeClient {
    public static let shared = InnertubeClient()
    public var cookie: String? {
        get { Keychain.get("innertubeCookie") }
        set { if let v = newValue { Keychain.set(v, for: "innertubeCookie") } else { Keychain.delete("innertubeCookie") } }
    }
    public var dataSyncId: String?
    public var pageId: String?
    public var visitorData: String?
    private let base = "https://music.youtube.com/youtubei/v1"
    private let clientVersion = "1.20250101.01.00" // fallback; the signed-in shell's live version wins when known
    private init() {}

    private func sapisidHash() -> String? {
        guard let cookie else { return nil }
        // SAPISID is a cookie value, e.g. "SAPISID=abc123; ..."
        let parts = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let sapisid = parts.first(where: { $0.hasPrefix("SAPISID=") })?.dropFirst("SAPISID=".count), !sapisid.isEmpty else { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        let hash = Crypto.sha1Hex("\(ts) \(sapisid) https://music.youtube.com")
        return "SAPISIDHASH \(ts)_\(hash)"
    }

    public func post(_ path: String, body: [String: Any]) async throws -> JSONValue {
        var context: [String: Any] = [
            "client": ["clientName": "WEB_REMIX", "clientVersion": clientVersion, "hl": "en", "gl": "US"],
            "user": [:] as [String: Any]
        ]
        if let visitorData { context["client"] = (context["client"] as? [String: Any] ?? [:]).merging(["visitorData": visitorData]) { _, new in new } }
        if let dataSyncId { context["user"] = ["onBehalfOfUser": dataSyncId] }
        var payload = body; payload["context"] = context
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let visitorData { req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        if let pageId { req.setValue(pageId, forHTTPHeaderField: "X-Goog-PageId") }
        if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let auth = sapisidHash() { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "Innertube", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Innertube \(path) returned HTTP \(http.statusCode)"])
        }
        return try JSONValue.parse(data)
    }

    /// Mint a visitor id from the www.youtube.com service-worker bootstrap,
    /// exactly as the original's fetchVisitorData does (shape, not path).
    public func ensureVisitorData(refresh: Bool = false) async -> String? {
        if !refresh, let visitorData { return visitorData }
        do {
            let url = URL(string: "https://www.youtube.com/sw.js_data")!
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            var text = String(data: data, encoding: .utf8) ?? ""
            if text.hasPrefix(")]}'") { text = String(text.dropFirst(4)) }
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let json = try? JSONValue.parse(Data(text.utf8)), let found = findVisitorData(json) {
                visitorData = found; return found
            }
        } catch { /* guest browsing continues without a visitor id; player calls may then fail honestly */ }
        return visitorData
    }
    private func findVisitorData(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s):
            if s.hasPrefix("Cg"), s.count >= 42, s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "%" || $0 == "-" }) { return s }
            return nil
        case .array(let a): return a.compactMap(findVisitorData).first
        case .object(let o): return o.values.compactMap(findVisitorData).first
        default: return nil
        }
    }

    public func browse(browseId: String, params: String? = nil) async throws -> JSONValue {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        return try await post("/browse", body: body)
    }
    public func search(query: String, params: String? = nil) async throws -> JSONValue {
        var body: [String: Any] = ["query": query]
        if let params { body["params"] = params }
        return try await post("/search", body: body)
    }
    public func searchContinuation(token: String) async throws -> JSONValue {
        try await post("/search", body: ["continuation": token])
    }
    public func browseContinuation(token: String) async throws -> JSONValue {
        try await post("/browse", body: ["continuation": token])
    }
    public func player(videoId: String) async throws -> JSONValue {
        var body: [String: Any] = ["videoId": videoId]
        if let poToken = StreamResolver.shared.poToken {
            body["serviceIntegrityDimensions"] = ["poToken": poToken]
        }
        return try await post("/player", body: body)
    }
    public func next(videoId: String, playlistId: String? = nil) async throws -> JSONValue {
        var body: [String: Any] = ["videoId": videoId, "enablePersistentPlaylistPanel": true]
        if let playlistId { body["playlistId"] = playlistId }
        return try await post("/next", body: body)
    }

    /// Parse musicResponsiveListItemRenderer rows into Tracks (shelves, search, detail lists).
    public static func parseTracks(from json: JSONValue) -> [Track] {
        var out: [Track] = []
        for item in json.findAllDeep("musicResponsiveListItemRenderer") {
            let title = item["flexColumns"][0]["musicResponsiveListItemFlexColumnRenderer"]["text"].runsText
            guard !title.isEmpty else { continue }
            let videoId = item["navigationEndpoint"]["watchEndpoint"]["videoId"].string
                ?? item["overlay"]["musicItemThumbnailOverlayRenderer"]["content"]["musicPlayButtonRenderer"]["playNavigationEndpoint"]["watchEndpoint"]["videoId"].string
                ?? ""
            guard !videoId.isEmpty else { continue }
            let artists = item["flexColumns"][1]["musicResponsiveListItemFlexColumnRenderer"]["text"]["runs"].array?
                .compactMap { $0["text"].string } ?? []
            let durationText = item["flexColumns"].array?.last?["musicResponsiveListItemFlexColumnRenderer"]["text"].runsText ?? ""
            out.append(Track(id: videoId, title: title.htmlUnescaped(), artists: artists, thumbnailURL: item["thumbnail"]["musicThumbnailRenderer"].thumbnailURL, durationSeconds: parseDuration(durationText)))
        }
        return out
    }
    public static func parseDuration(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return 0
    }
    /// Continuation token from a response, if the list paginates.
    public static func continuationToken(from json: JSONValue) -> String? {
        json.findAllDeep("continuationItemRenderer").first?["continuationEndpoint"]["continuationCommand"]["token"].string
    }
}
