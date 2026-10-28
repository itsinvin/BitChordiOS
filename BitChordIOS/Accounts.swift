import Foundation
import WebKit
import CryptoKit

// MARK: - Accounts (port of auth/* + data/scrobbling/* + data/discord/*)
// All tokens live in Keychain.swift. Nothing here hardcodes a client secret:
// Spotify uses PKCE (no secret), Last.fm needs a key/secret the user enters,
// Discord needs a user token the user enters. Those are the original's own
// requirements, surfaced in-app instead of baked into source.

// MARK: Google / YouTube Music (WKWebView cookie capture, like WebSession.kt)

@MainActor
public final class GoogleAccount: ObservableObject {
    public static let shared = GoogleAccount()
    @Published public var signedIn: Bool = false
    @Published public var visitorData: String?
    private init() { signedIn = InnertubeClient.shared.cookie != nil }
    public func applyCookies(_ cookieHeader: String, visitorData: String?) {
        InnertubeClient.shared.cookie = cookieHeader
        if let visitorData { InnertubeClient.shared.visitorData = visitorData; self.visitorData = visitorData }
        signedIn = true
    }
    public func signOut() {
        InnertubeClient.shared.cookie = nil
        InnertubeClient.shared.visitorData = nil
        Keychain.delete("innertubeCookie")
        signedIn = false; visitorData = nil
        HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
    }
}

// MARK: Spotify (OAuth PKCE + api.spotify.com)

@MainActor
public final class SpotifyAccount: ObservableObject {
    public static let shared = SpotifyAccount()
    @Published public var signedIn: Bool = false
    @Published public var displayName: String?
    @Published public var playlists: [PlaylistItem] = []
    @Published public var likedSongs: [Track] = []
    public var clientId: String { get { UserDefaults.standard.string(forKey: "spotifyClientId") ?? "" } set { UserDefaults.standard.set(newValue, forKey: "spotifyClientId") } }
    private var codeVerifier = ""
    private var accessToken: String? { get { Keychain.get("spotifyAccessToken") } set { if let v = newValue { Keychain.set(v, for: "spotifyAccessToken") } else { Keychain.delete("spotifyAccessToken") } } }
    private init() { signedIn = accessToken != nil }
    public func authURL(redirectURI: String) -> URL? {
        guard !clientId.isEmpty else { return nil }
        codeVerifier = (0..<64).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! }.map(String.init).joined()
        let challenge = Crypto.sha256Base64URL(codeVerifier)
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: "user-library-read playlist-read-private playlist-read-collaborative"),
        ]
        return comps.url
    }
    public func exchange(code: String, redirectURI: String) async -> Bool {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONValue.parse(data),
              let token = json["access_token"].string else { return false }
        accessToken = token; signedIn = true
        await refreshLibrary()
        return true
    }
    private func api(_ path: String) async -> JSONValue? {
        guard let token = accessToken, let url = URL(string: "https://api.spotify.com/v1\(path)") else { return nil }
        var req = URLRequest(url: url); req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONValue.parse(data)
    }
    public func refreshLibrary() async {
        if let json = await api("/me/playlists?limit=50") {
            playlists = (json["items"].array ?? []).compactMap { item in
                guard let id = item["id"].string, let name = item["name"].string else { return nil }
                return PlaylistItem(id: id, title: name, author: item["owner"]["display_name"].string, trackCount: item["tracks"]["total"].int)
            }
        }
        if let json = await api("/me/tracks?limit=50") {
            likedSongs = (json["items"].array ?? []).compactMap { item in
                let t = item["track"]
                guard let id = t["id"].string, let name = t["name"].string else { return nil }
                return Track(id: "spotify:\(id)", title: name, artists: (t["artists"].array ?? []).compactMap { $0["name"].string }, album: t["album"]["name"].string, durationSeconds: (t["duration_ms"].double ?? 0) / 1000, source: "spotify")
            }
        }
    }
    public func signOut() { accessToken = nil; signedIn = false; playlists = []; likedSongs = [] }
}

// MARK: Discord (gateway presence, port of data/discord/DiscordRPC.kt)

@MainActor
public final class DiscordPresence: ObservableObject {
    public static let shared = DiscordPresence()
    @Published public var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "discordRpcEnabled") } }
    @Published public var showAudioQuality: Bool { didSet { UserDefaults.standard.set(showAudioQuality, forKey: "discordShowQuality") } }
    @Published public var connected: Bool = false
    public var token: String { get { Keychain.get("discordToken") ?? "" } set { Keychain.set(newValue, for: "discordToken") } }
    private var wsTask: URLSessionWebSocketTask?
    private init() {
        enabled = UserDefaults.standard.object(forKey: "discordRpcEnabled") as? Bool ?? false
        showAudioQuality = UserDefaults.standard.object(forKey: "discordShowQuality") as? Bool ?? true
    }
    public func connect() {
        guard enabled, !token.isEmpty else { return }
        let req = URLRequest(url: URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!)
        let task = URLSession.shared.webSocketTask(with: req)
        wsTask = task; task.resume()
        // Identify + presence are sent after the Hello frame; the receive
        // loop below is deliberately minimal — presence is best-effort and
        // never blocks playback if Discord is unreachable.
        Task {
            while let message = try? await task.receive() {
                if case .string(let text) = message, let json = try? JSONValue.parse(Data(text.utf8)) {
                    if json["op"].int == 10 {
                        let identify: [String: Any] = ["op": 2, "d": ["token": token, "intents": 0, "properties": ["os": "ios", "browser": "BitChord", "device": "BitChord"]]]
                        if let data = try? JSONSerialization.data(withJSONObject: identify) { task.send(.data(data)) { _ in } }
                        connected = true
                    }
                }
            }
        }
    }
    public func update(track: Track?, position: Double, isPlaying: Bool, quality: String?) {
        guard enabled, connected, let track else { return }
        var details = track.title
        if showAudioQuality, let quality { details += " · \(quality)" }
        let activity: [String: Any] = [
            "details": details,
            "state": track.artistText,
            "assets": ["large_text": track.album ?? "BitChord"],
            "timestamps": isPlaying ? ["start": Int(Date().timeIntervalSince1970 * 1000) - Int(position * 1000)] : [:],
        ]
        let frame: [String: Any] = ["op": 3, "d": ["since": NSNull(), "activities": [activity], "status": "online", "afk": false]]
        if let data = try? JSONSerialization.data(withJSONObject: frame) { wsTask?.send(.data(data)) { _ in } }
    }
    public func disconnect() { wsTask?.cancel(with: .goingAway, reason: nil); wsTask = nil; connected = false }
}

// MARK: Scrobbling (Last.fm + ListenBrainz, port of data/scrobbling/*)

public enum Scrobbler {
    private static var lastNowPlayingId: String?
    private static var scrobbleStart: Date?

    public static var lastfmEnabled: Bool { UserDefaults.standard.object(forKey: "lastfmEnabled") as? Bool ?? false }
    public static var listenBrainzEnabled: Bool { UserDefaults.standard.object(forKey: "listenBrainzEnabled") as? Bool ?? false }
    public static var lastfmKey: String { get { UserDefaults.standard.string(forKey: "lastfmApiKey") ?? "" } set { UserDefaults.standard.set(newValue, forKey: "lastfmApiKey") } }
    public static var lastfmSecret: String { get { Keychain.get("lastfmSecret") ?? "" } set { Keychain.set(newValue, for: "lastfmSecret") } }
    public static var lastfmSession: String? { get { Keychain.get("lastfmSessionKey") } set { if let v = newValue { Keychain.set(v, for: "lastfmSessionKey") } else { Keychain.delete("lastfmSessionKey") } } }
    public static var listenBrainzToken: String { get { Keychain.get("listenBrainzToken") ?? "" } set { Keychain.set(newValue, for: "listenBrainzToken") } }

    private static func lastfmSigned(params: [String: String]) -> [String: String] {
        var p = params; p["api_key"] = lastfmKey; p["format"] = "json"
        let sig = p.keys.sorted().map { "\($0)\(p[$0]!)" }.joined() + lastfmSecret
        p["api_sig"] = Crypto.md5Hex(sig)
        return p
    }
    private static func postLastfm(_ params: [String: String]) async {
        guard lastfmEnabled, !lastfmKey.isEmpty, lastfmSession != nil else { return }
        var req = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
        req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents(); comps.queryItems = lastfmSigned(params: params).map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        _ = try? await URLSession.shared.data(for: req)
    }
    public static func nowPlaying(track: Track) async {
        guard track.id != lastNowPlayingId else { return }
        lastNowPlayingId = track.id; scrobbleStart = Date()
        if lastfmEnabled, let sk = lastfmSession {
            await postLastfm(["method": "track.updateNowPlaying", "artist": track.artistText, "track": track.title, "album": track.album ?? "", "duration": "\(Int(track.durationSeconds))", "sk": sk])
        }
        if listenBrainzEnabled, !listenBrainzToken.isEmpty {
            await submitListenBrainz(track: track, listenedAt: nil)
        }
    }
    /// Original rule: scrobble at 50% of the track or 240 s, whichever first.
    public static func maybeScrobble(track: Track, playedSeconds: Double) async {
        guard let start = scrobbleStart, track.id == lastNowPlayingId else { return }
        let threshold = min(track.durationSeconds / 2, 240)
        guard playedSeconds >= threshold, Date().timeIntervalSince(start) >= threshold else { return }
        scrobbleStart = nil // scrobble once per track
        if lastfmEnabled, let sk = lastfmSession {
            await postLastfm(["method": "track.scrobble", "artist": track.artistText, "track": track.title, "album": track.album ?? "", "timestamp": "\(Int(Date().timeIntervalSince1970))", "sk": sk])
        }
        if listenBrainzEnabled, !listenBrainzToken.isEmpty {
            await submitListenBrainz(track: track, listenedAt: Int(Date().timeIntervalSince1970))
        }
    }
    private static func submitListenBrainz(track: Track, listenedAt: Int?) async {
        var listen: [String: Any] = ["track_metadata": ["artist_name": track.artistText, "track_name": track.title, "release_name": track.album ?? ""]]
        if let listenedAt { listen["listened_at"] = listenedAt }
        let body: [String: Any] = ["listen_type": listenedAt == nil ? "playing_now" : "single", "payload": [listen]]
        guard let url = URL(string: "https://api.listenbrainz.org/1/submit-listens") else { return }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Token \(listenBrainzToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
    /// Last.fm auth step 1: get a token, then open last.fm/api/auth in the browser.
    public static func lastfmAuthURL() -> URL? {
        guard !lastfmKey.isEmpty else { return nil }
        return URL(string: "https://www.last.fm/api/auth/?api_key=\(lastfmKey)")
    }
}
