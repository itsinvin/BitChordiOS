import Foundation
import UIKit
import CommonCrypto

// MARK: - Listen Together (port of backend/protocol + backend README + Android ListenTogether.kt)
//
// Protocol, verbatim from original/backend/README.md and backend/protocol/protocol.go:
//  * REST on the API host (default https://api.bitchord.kushagrasingh.in).
//    Invite links use a DIFFERENT origin: https://bitchord.kushagrasingh.in/invite/<CODE>.
//  * POST /api/parties -> 201 {code, token, you, party}; POST /api/parties/{code}/join
//    -> 200 same shape (404 unknown, 409 full, 422 no identity); GET /api/parties/{code}
//    and POST /api/parties/{code}/leave with Authorization: Bearer <token>.
//  * WebSocket /ws/parties/{code} with Authorization: Bearer <token> on the
//    handshake request. The token is NEVER put in the URL (it would land in logs).
//  * Clock: offset = serverMs - (t0 + t1) / 2 from ping/pong; keep the
//    smallest-RTT sample. playhead = positionMs + max(0, serverNow - anchorMs)
//    while playing, else positionMs. Play/seek anchor 350 ms ahead (JAM_PLAY_LEAD_MS).
//  * Ignore any state frame whose playback.seq is not greater than the last
//    applied seq. State carries only queueSeq/queueIndex/queueLength; the queue
//    itself arrives in welcome/snapshot and queue frames — if a state's queueSeq
//    disagrees with the held queue's seq, send syncQueue.
//  * Track wire format is ONLY {videoId, title, artist, thumbnailUrl, durationMs,
//    fromAutoplay}. Stream URLs are never shared: each device resolves its own
//    via StreamResolver from the videoId.
//  * Server constants: max 5 members (default), 25 upcoming queue items,
//    5 s server heartbeat, 45 s disconnect grace, host-only control flag.

public enum PartyConnectionState: String, CaseIterable {
    case idle, connecting, connected, reconnecting, error
    public var label: String {
        switch self { case .idle: return "Not in a party"; case .connecting: return "Connecting…"; case .connected: return "Connected"; case .reconnecting: return "Reconnecting…"; case .error: return "Connection error" }
    }
}

public struct PartyMember: Identifiable, Equatable {
    public var id: String { memberId }
    public var memberId: String; public var userId: String; public var displayName: String
    public var avatarURL: String?; public var isHost: Bool; public var connected: Bool; public var joinedAtMs: Int64
    public init(memberId: String, userId: String = "", displayName: String, avatarURL: String? = nil, isHost: Bool = false, connected: Bool = true, joinedAtMs: Int64 = 0) {
        self.memberId = memberId; self.userId = userId; self.displayName = displayName; self.avatarURL = avatarURL; self.isHost = isHost; self.connected = connected; self.joinedAtMs = joinedAtMs
    }
    static func parse(_ j: JSONValue) -> PartyMember? {
        guard let memberId = j["memberId"].string, let name = j["displayName"].string else { return nil }
        return PartyMember(memberId: memberId, userId: j["userId"].string ?? "", displayName: name, avatarURL: j["avatarUrl"].string, isHost: j["isHost"].bool ?? (j["isHost"].double == 1), connected: j["connected"].bool ?? (j["connected"].double != 0), joinedAtMs: Int64(j["joinedAtMs"].double ?? 0))
    }
}

public struct PartyTrackWire: Equatable {
    public var videoId: String; public var title: String; public var artist: String
    public var thumbnailURL: String?; public var durationMs: Int64?; public var fromAutoplay: Bool
    public func toTrack() -> Track {
        Track(id: videoId, title: title, artists: artist.isEmpty ? [] : [artist], thumbnailURL: thumbnailURL, durationSeconds: Double(durationMs ?? 0) / 1000.0)
    }
    public static func from(_ track: Track, fromAutoplay: Bool = false) -> PartyTrackWire {
        PartyTrackWire(videoId: track.id, title: track.title, artist: track.artistText, thumbnailURL: track.thumbnailURL, durationMs: Int64(track.durationSeconds * 1000), fromAutoplay: fromAutoplay)
    }
    public func wireDict() -> [String: Any] {
        var d: [String: Any] = ["videoId": videoId, "title": title, "artist": artist, "fromAutoplay": fromAutoplay]
        if let thumbnailURL { d["thumbnailUrl"] = thumbnailURL }
        if let durationMs { d["durationMs"] = durationMs }
        return d
    }
    static func parse(_ j: JSONValue) -> PartyTrackWire? {
        guard let videoId = j["videoId"].string, !videoId.isEmpty else { return nil }
        return PartyTrackWire(videoId: videoId, title: j["title"].string ?? "", artist: j["artist"].string ?? "", thumbnailURL: j["thumbnailUrl"].string, durationMs: j["durationMs"].double.map(Int64.init), fromAutoplay: j["fromAutoplay"].bool ?? (j["fromAutoplay"].double == 1))
    }
}

public struct PartyPlayback: Equatable {
    public var seq: Int; public var queueSeq: Int; public var queueIndex: Int; public var queueLength: Int
    public var isPlaying: Bool; public var positionMs: Int64; public var anchorMs: Int64
    public var track: PartyTrackWire?; public var startedBy: String?; public var startedByName: String?; public var updatedBy: String?; public var autoplayEnabled: Bool
    static func parse(_ j: JSONValue) -> PartyPlayback? {
        guard let seq = j["seq"].int else { return nil }
        return PartyPlayback(seq: seq, queueSeq: j["queueSeq"].int ?? 0, queueIndex: j["queueIndex"].int ?? -1, queueLength: j["queueLength"].int ?? 0, isPlaying: j["isPlaying"].bool ?? (j["isPlaying"].double == 1), positionMs: Int64(j["positionMs"].double ?? 0), anchorMs: Int64(j["anchorMs"].double ?? 0), track: PartyTrackWire.parse(j["track"]), startedBy: j["startedBy"].string, startedByName: j["startedByName"].string, updatedBy: j["updatedBy"].string, autoplayEnabled: j["autoplayEnabled"].bool ?? (j["autoplayEnabled"].double == 1))
    }
}

/// NTP-style clock. Only the smallest-RTT ping/pong sample sets the offset.
public struct PartyClock {
    public var offsetMs: Int64 = 0
    public var bestRTTMs: Int64 = Int64.max
    public var synced: Bool = false
    public var lastRTTMs: Int64?
    public mutating func record(sentMs: Int64, serverMs: Int64, receivedMs: Int64) {
        let rtt = receivedMs - sentMs; lastRTTMs = rtt
        guard rtt >= 0, rtt < bestRTTMs else { return }
        bestRTTMs = rtt; offsetMs = serverMs - (sentMs + receivedMs) / 2; synced = true
    }
    public mutating func reset() { offsetMs = 0; bestRTTMs = Int64.max; synced = false; lastRTTMs = nil }
    public func serverNowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) + offsetMs }
    public func deviceNowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    /// Server-side PositionAt, mirrored: clamped to the track duration when known.
    public func positionAt(_ playback: PartyPlayback) -> Int64 {
        guard playback.isPlaying else { return playback.positionMs }
        let pos = playback.positionMs + max(0, serverNowMs() - playback.anchorMs)
        if let d = playback.track?.durationMs, d > 0 { return min(pos, d) }
        return pos
    }
    /// Milliseconds until the play/seek anchor is reached (0 if already past it).
    public func leadDelayMs(for playback: PartyPlayback) -> Int64 {
        guard playback.isPlaying else { return 0 }
        return max(0, playback.anchorMs - serverNowMs())
    }
}

public struct PartyError: LocalizedError {
    public var code: String; public var message: String; public var status: Int; public var attemptedURL: String?
    public var errorDescription: String? {
        if let attemptedURL { return "\(message) (tried \(attemptedURL))" }
        return message
    }
}

@MainActor
public final class ListenTogether: ObservableObject {
    public static let shared = ListenTogether()
    public static let defaultAPIHost = "https://api.bitchord.kushagrasingh.in"
    public static let inviteOrigin = "https://bitchord.kushagrasingh.in"
    public static let playLeadMs: Int64 = 350
    public static let maxMembersDefault = 5
    public static let maxUpcoming = 25
    public static let disconnectGraceMs: Int64 = 45_000
    public static let kickBlockMs: Int64 = 24 * 60 * 60 * 1000

    @Published public var serverBaseURL: String {
        didSet { UserDefaults.standard.set(serverBaseURL, forKey: "listenTogetherServerBase") }
    }
    @Published public var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: "listenTogetherDisplayName") }
    }
    @Published public var connectionState: PartyConnectionState = .idle
    @Published public var code: String?
    @Published public var members: [PartyMember] = []
    @Published public var maxMembers: Int = maxMembersDefault
    @Published public var hostOnlyControl: Bool = false
    @Published public var you: PartyMember?
    @Published public var playback: PartyPlayback?
    @Published public var queue: [PartyTrackWire] = []
    @Published public var queueIndex: Int = -1
    @Published public var queueSeq: Int = -1
    @Published public var lastServerError: String?
    @Published public var byeReason: String?
    @Published public var lastActivity: String?
    @Published public var clockSynced: Bool = false
    @Published public var roundTripMs: Int64?
    @Published public var lastAttemptedURL: String?
    @Published public var isInParty: Bool = false

    public var inviteURL: String? { code.map { "\(Self.inviteOrigin)/invite/\($0)" } }
    public var canControl: Bool { !hostOnlyControl || (you?.isHost ?? false) }
    public var upcomingCount: Int { queueIndex >= 0 ? max(0, queue.count - queueIndex - 1) : queue.count }
    public var isQueueFull: Bool { upcomingCount >= Self.maxUpcoming }

    private var token: String?
    private var wsTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var intentionalDisconnect = false
    private var lastAppliedSeq = -1
    private var lastAppliedQueueSeq = -1
    private var clock = PartyClock()
    private var reconnectAttempts = 0

    private init() {
        self.serverBaseURL = UserDefaults.standard.string(forKey: "listenTogetherServerBase") ?? Self.defaultAPIHost
        self.displayName = UserDefaults.standard.string(forKey: "listenTogetherDisplayName") ?? "Listener"
    }

    // MARK: - Codes (backend/codes/codes.go: Normalise + JamInvite)

    public static func normalizeCode(_ raw: String) -> String {
        var out = ""
        for ch in raw.uppercased() where ch.isLetter || ch.isNumber {
            switch ch { case "I", "L": out.append("1"); case "O": out.append("0"); default: out.append(ch) }
        }
        return out
    }
    public static func isValidCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { "0123456789ABCDEFGHJKMNPQRSTUVWXYZ".contains($0) }
    }
    public static func parseInviteURL(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(inviteOrigin)/invite/"
        guard text.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        var code = String(text.dropFirst(prefix.count))
        code = code.components(separatedBy: "?").first ?? code
        code = code.components(separatedBy: "#").first ?? code
        guard code.count == 6, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return code.uppercased()
    }

    // MARK: - Identity (stable, account-free: sha256(deviceId) like Android's sha256(account:profile))

    public var deviceId: String {
        if let saved = UserDefaults.standard.string(forKey: "listenTogetherDeviceId") { return saved }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: "listenTogetherDeviceId"); return id
    }
    public var userId: String { String(sha256Hex(deviceId).prefix(32)) }
    private func sha256Hex(_ s: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let data = Data(s.utf8)
        data.withUnsafeBytes { CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    private var identityBody: [String: Any] {
        var body: [String: Any] = ["userId": userId, "deviceId": deviceId, "displayName": displayName.trimmingCharacters(in: .whitespacesAndNewlines)]
        return body
    }
    private func tokenKey(for code: String) -> String { "listenTogether.token.\(code)" }
    private func storeToken(_ token: String, code: String) {
        self.token = token; Keychain.set(token, for: tokenKey(for: code))
    }
    private func clearToken(for code: String) { Keychain.delete(tokenKey(for: code)); if self.code == code { token = nil } }
    private func kickedUntil(for code: String) -> Int64? {
        let map = UserDefaults.standard.dictionary(forKey: "listenTogetherKicked") as? [String: Int64]
        guard let until = map?[code], until > Int64(Date().timeIntervalSince1970 * 1000) else { return nil }
        return until
    }
    private func recordKick(for code: String) {
        var map = (UserDefaults.standard.dictionary(forKey: "listenTogetherKicked") as? [String: Int64]) ?? [:]
        map[code] = Int64(Date().timeIntervalSince1970 * 1000) + Self.kickBlockMs
        UserDefaults.standard.set(map, forKey: "listenTogetherKicked")
    }

    // MARK: - REST

    private func httpBase() -> String {
        var base = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.isEmpty { base = Self.defaultAPIHost }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") { base = "https://" + base }
        return base
    }
    private func wsBase() -> String {
        httpBase().replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
    }
    private func rest(_ method: String, _ path: String, body: [String: Any]? = nil, authed: Bool = false) async throws -> (Int, JSONValue) {
        let urlString = httpBase() + path
        lastAttemptedURL = urlString
        guard let url = URL(string: urlString) else { throw PartyError(code: "bad_url", message: "Bad party server URL.", status: 0, attemptedURL: urlString) }
        var req = URLRequest(url: url); req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authed, let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw PartyError(code: "unreachable", message: "Could not reach the party server.", status: 0, attemptedURL: urlString) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONValue.parse(data)) ?? .null
        if !(200...299).contains(status) {
            let serverCode = json["error"].string ?? "server_error"
            let serverMessage = json["message"].string
            let message: String
            switch (status, serverCode) {
            case (404, _): message = "No party with that code."
            case (409, "party_full"): message = "This party is full (\(maxMembers) devices)."
            case (422, _): message = serverMessage ?? "Your display name or device identity was rejected."
            case (401, _): message = "This device is not a member of that party (bad token)."
            case (429, _): message = "Too many party requests — try again shortly."
            default: message = serverMessage ?? "Party server error (HTTP \(status))."
            }
            throw PartyError(code: serverCode, message: message, status: status, attemptedURL: urlString)
        }
        return (status, json)
    }

    public func checkHealth() async -> Bool {
        do {
            let (_, _) = try await rest("GET", "/healthz")
            lastServerError = nil; return true
        } catch let e as PartyError {
            lastServerError = e.errorDescription; connectionState = .error; return false
        } catch { lastServerError = error.localizedDescription; connectionState = .error; return false }
    }
    /// First clock estimate before any socket exists (GET /api/time), as the README prescribes.
    public func fetchServerTime() async {
        let t0 = clock.deviceNowMs()
        do {
            let (_, json) = try await rest("GET", "/api/time")
            let t1 = clock.deviceNowMs()
            if let serverMs = json["serverMs"].double.map(Int64.init) { clock.record(sentMs: t0, serverMs: serverMs, receivedMs: t1); clockSynced = clock.synced; roundTripMs = clock.lastRTTMs }
        } catch { /* socket pings will refine/replace this; never block joining on it */ }
    }

    public func createParty() async throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PartyError(code: "no_identity", message: "Enter a display name first.", status: 0, attemptedURL: nil)
        }
        var body = identityBody; body["maxMembers"] = Self.maxMembersDefault; body["autoplayEnabled"] = true
        let (_, json) = try await rest("POST", "/api/parties", body: body)
        guard let newCode = json["code"].string, let newToken = json["token"].string else {
            throw PartyError(code: "bad_response", message: "The server did not return a party code and token.", status: 0, attemptedURL: lastAttemptedURL)
        }
        storeToken(newToken, code: newCode)
        applySnapshot(party: json["party"], you: json["you"])
        await connectSocket()
    }

    public func joinParty(rawCode: String) async throws {
        let normalized = Self.normalizeCode(rawCode)
        guard Self.isValidCode(normalized) else {
            throw PartyError(code: "bad_code", message: "A party code is six letters or digits (I/L count as 1, O counts as 0).", status: 0, attemptedURL: nil)
        }
        if kickedUntil(for: normalized) != nil {
            throw PartyError(code: "recently_kicked", message: "You were recently removed from this party, so you can't rejoin it for 24 hours.", status: 0, attemptedURL: nil)
        }
        let (_, json) = try await rest("POST", "/api/parties/\(normalized)/join", body: identityBody)
        guard let newToken = json["token"].string else {
            throw PartyError(code: "bad_response", message: "The server did not return a join token.", status: 0, attemptedURL: lastAttemptedURL)
        }
        storeToken(newToken, code: normalized)
        applySnapshot(party: json["party"], you: json["you"])
        await connectSocket()
    }

    /// Reconnect within the 45 s grace period reusing the stored token — no new
    /// REST join, so the same device slot is reclaimed instead of filling a new one.
    public func reconnectWithStoredToken(code: String) async {
        guard let saved = Keychain.get(tokenKey(for: code)) else {
            lastServerError = "No saved party token for \(code) — join again with the code."; connectionState = .error; return
        }
        self.code = code; token = saved; isInParty = true
        await fetchServerTime()
        await connectSocket()
    }

    /// Authenticated snapshot (GET /api/parties/{code}) — the same party object
    /// the welcome frame carries, usable to refresh members/playback/queue
    /// without rejoining. Requires the stored token; 401 means it is stale.
    public func fetchPartySnapshot() async throws {
        guard let code else { throw PartyError(code: "no_party", message: "Not in a party.", status: 0, attemptedURL: nil) }
        let (_, json) = try await rest("GET", "/api/parties/\(code)", authed: true)
        applySnapshot(party: json, you: .null)  // .null keeps the existing 'you'; snapshot carries no new member object
    }

    public func leaveParty() async {
        let leavingCode = code
        intentionalDisconnect = true
        cancelSocketTasks()
        if let leavingCode, token != nil {
            _ = try? await rest("POST", "/api/parties/\(leavingCode)/leave", authed: true)
            clearToken(for: leavingCode)
        }
        PlayerEngine.shared.detachParty()
        resetPartyState()
        intentionalDisconnect = false
    }
    private func leaveLocally(reason: String) {
        // Server no longer knows this device (bad token / party gone / kicked):
        // stop dialling it, keep the reason visible, do not call leave (it would 401).
        let leavingCode = code
        intentionalDisconnect = true
        cancelSocketTasks()
        if let leavingCode { clearToken(for: leavingCode) }
        PlayerEngine.shared.detachParty()
        let reasonText = reason
        resetPartyState()
        byeReason = reasonText; lastServerError = reasonText; connectionState = .error
        intentionalDisconnect = false
    }
    private func resetPartyState() {
        UserDefaults.standard.removeObject(forKey: "listenTogetherLastCode")
        code = nil; members = []; maxMembers = Self.maxMembersDefault; hostOnlyControl = false; you = nil
        playback = nil; queue = []; queueIndex = -1; queueSeq = -1; isInParty = false
        lastAppliedSeq = -1; lastAppliedQueueSeq = -1; clock.reset(); clockSynced = false; roundTripMs = nil
    }
    private func cancelSocketTasks(cancelReconnect: Bool = true) {
        receiveTask?.cancel(); pingTask?.cancel(); reportTask?.cancel()
        receiveTask = nil; pingTask = nil; reportTask = nil
        if cancelReconnect { reconnectTask?.cancel(); reconnectTask = nil }
        wsTask?.cancel(with: .goingAway, reason: nil); wsTask = nil
    }

    // MARK: - Snapshot (welcome / REST party object)

    private func applySnapshot(party: JSONValue, you youJson: JSONValue) {
        code = party["code"].string ?? code
        members = party["members"].array?.compactMap(PartyMember.parse) ?? members
        maxMembers = party["maxMembers"].int ?? maxMembers
        if !party["hostOnlyControl"].isNull { hostOnlyControl = party["hostOnlyControl"].bool ?? (party["hostOnlyControl"].double == 1) }
        if let me = PartyMember.parse(youJson) { you = me }
        if let pb = PartyPlayback.parse(party["playback"]) {
            playback = pb; lastAppliedSeq = pb.seq
            if let q = party["queue"].object {
                queueSeq = q["seq"]?.int ?? queueSeq; lastAppliedQueueSeq = queueSeq
                queueIndex = q["index"]?.int ?? pb.queueIndex
                queue = q["items"]?.array?.compactMap(PartyTrackWire.parse) ?? []
            }
        }
        isInParty = code != nil
        if let code { UserDefaults.standard.set(code, forKey: "listenTogetherLastCode") }
        PlayerEngine.shared.partyDelegate = self
        if let pb = playback { applyPlaybackToPlayer(pb) }
    }

    // MARK: - WebSocket

    private func connectSocket() async {
        guard let code, let token else { lastServerError = "No party token — join or create a party first."; connectionState = .error; return }
        let wsURLString = wsBase() + "/ws/parties/\(code)"
        lastAttemptedURL = wsURLString
        guard let wsURL = URL(string: wsURLString) else { lastServerError = "Bad party server URL: \(wsURLString)"; connectionState = .error; return }
        cancelSocketTasks(cancelReconnect: false)
        intentionalDisconnect = false
        connectionState = .connecting
        await fetchServerTime()
        // Authorization header on the handshake request. The token is NOT in
        // the URL: URL query strings end up in access logs.
        var request = URLRequest(url: wsURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        wsTask = task; task.resume()
        isInParty = true
        PlayerEngine.shared.partyDelegate = self
        startReceiveLoop()
        startPingLoop()
        startReportLoop()
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = await self.wsTask else { return }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text): await self.handleFrame(text)
                    case .data(let data): if let text = String(data: data, encoding: .utf8) { await self.handleFrame(text) }
                    @unknown default: break
                    }
                } catch {
                    if Task.isCancelled { return }
                    await self.handleSocketDrop(error: error)
                    return
                }
            }
        }
    }
    private func handleSocketDrop(error: Error) async {
        wsTask = nil; pingTask?.cancel(); reportTask?.cancel()
        guard !intentionalDisconnect, isInParty else { return }
        // Clock is not carried across a gap (Android resets it on drop): the
        // offset measured before the gap is not the offset after it.
        clock.reset(); clockSynced = false
        connectionState = .reconnecting
        lastServerError = "Party connection dropped — reconnecting (tried \(lastAttemptedURL ?? wsBase())). Your slot survives for 45 seconds."
        scheduleReconnect()
    }
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            var delayMs = 1_000
            while !Task.isCancelled {
                // Jittered exponential backoff, capped at 30 s (Android's shape).
                let jitter = Int.random(in: 0...(delayMs))
                try? await Task.sleep(nanoseconds: UInt64(delayMs / 2 + jitter) * 1_000_000)
                guard !Task.isCancelled, await self.isInParty, await self.intentionalDisconnect == false else { return }
                await self.connectSocket()
                // Wait for the outcome (welcome -> connected, or drop -> reconnecting)
                // instead of redialling a socket that is still connecting.
                for _ in 0..<30 {
                    if Task.isCancelled { return }
                    if await self.connectionState == .connected { return }
                    if await self.connectionState != .connecting { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if await self.connectionState == .connected { return }
                delayMs = min(delayMs * 2, 30_000)
                await self.bumpReconnectAttempt()
                if await self.reconnectAttempts > 20 {
                    await self.failReconnect(); return
                }
            }
        }
    }
    private func bumpReconnectAttempt() { reconnectAttempts += 1 }
    private func failReconnect() {
        connectionState = .error
        lastServerError = "Could not reconnect to the party server at \(lastAttemptedURL ?? httpBase()). Your party code (\(code ?? "")) and token are still saved — tap Reconnect to try again."
    }
    public func manualReconnect() async {
        reconnectAttempts = 0
        if let code { await reconnectWithStoredToken(code: code) } else { connectionState = .error; lastServerError = "No party to reconnect to." }
    }

    private func startPingLoop() {
        pingTask = Task { [weak self] in
            guard let self else { return }
            // Burst on arrival, then a slow trickle (Android: 4 x 300 ms, then 15 s).
            for _ in 0..<4 {
                if Task.isCancelled { return }
                await self.sendPing(); try? await Task.sleep(nanoseconds: 300_000_000)
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await self.sendPing()
            }
        }
    }
    private func sendPing() {
        sendJSON(["type": "ping", "clientMs": clock.deviceNowMs()])
    }
    private func startReportLoop() {
        reportTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                let player = PlayerEngine.shared
                await self.sendJSON(["type": "report", "positionMs": Int(player.position * 1000), "isPlaying": player.isPlaying])
            }
        }
    }
    private func sendJSON(_ dict: [String: Any]) {
        guard let task = wsTask, connectionState != .idle else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: dict), let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            if let error { Task { @MainActor in self?.lastServerError = "Could not send to the party: \(error.localizedDescription)" } }
        }
    }
    private func sendControl(_ action: String, _ extra: [String: Any] = [:]) {
        var frame: [String: Any] = ["type": "control", "action": action]
        for (k, v) in extra { frame[k] = v }
        sendJSON(frame)
    }

    // MARK: - Incoming frames

    private func handleFrame(_ text: String) async {
        guard let data = text.data(using: .utf8), let json = try? JSONValue.parse(data) else { return }
        let type = json["type"].string ?? ""
        let receivedMs = clock.deviceNowMs()
        switch type {
        case "welcome":
            connectionState = .connected; reconnectAttempts = 0; lastServerError = nil
            applySnapshot(party: json["party"], you: json["you"])
            sendJSON(["type": "sync"])
        case "pong":
            if let sent = json["clientMs"].double.map(Int64.init), let serverMs = json["serverMs"].double.map(Int64.init) {
                clock.record(sentMs: sent, serverMs: serverMs, receivedMs: receivedMs)
                clockSynced = clock.synced; roundTripMs = clock.lastRTTMs
            }
        case "state":
            guard let pb = PartyPlayback.parse(json["playback"]) else { return }
            // The guard that keeps two simultaneous controllers from sending
            // each other backwards: stale or duplicate seq is ignored.
            guard pb.seq > lastAppliedSeq else { return }
            lastAppliedSeq = pb.seq; playback = pb
            if pb.queueSeq != lastAppliedQueueSeq { sendJSON(["type": "syncQueue"]) }
            applyPlaybackToPlayer(pb)
        case "queue":
            let q = json["queue"]
            guard let seq = q["seq"].int, seq >= lastAppliedQueueSeq else { return }
            lastAppliedQueueSeq = seq; queueSeq = seq
            queueIndex = q["index"].int ?? queueIndex
            queue = q["items"].array?.compactMap(PartyTrackWire.parse) ?? queue
            if let current = playback?.track {
                let tracks = queue.map { $0.toTrack() }
                let idx = queue.firstIndex(of: current) ?? queueIndex
                PlayerEngine.shared.applyPartyQueue(tracks, index: idx)
            }
        case "members":
            members = json["members"].array?.compactMap(PartyMember.parse) ?? members
            maxMembers = json["maxMembers"].int ?? maxMembers
            if !json["hostOnlyControl"].isNull { hostOnlyControl = json["hostOnlyControl"].bool ?? (json["hostOnlyControl"].double == 1) }
            // Promotion is announced only here: refresh "you" from the new list.
            if let me = you, let updated = members.first(where: { $0.memberId == me.memberId }) { you = updated }
        case "activity":
            if let by = json["by"].string, let detail = json["detail"].string {
                lastActivity = "\(by): \(detail)"
            }
        case "error":
            let errCode = json["error"].string ?? "server_error"
            let message = json["message"].string ?? errCode
            lastServerError = message
            // Terminal: the server no longer knows this device (e.g. it restarted).
            // Reconnecting would be answered forever, so stop and say so.
            if errCode == "bad_token" || errCode == "no_such_party" {
                leaveLocally(reason: message)
            }
        case "bye":
            let reason = json["reason"].string ?? "left"
            if reason == "kicked", let c = code { recordKick(for: c) }
            leaveLocally(reason: reason == "kicked" ? "The host removed you from this party." : "You left the party.")
            byeReason = reason
        default: break
        }
    }

    // MARK: - Apply remote playback to the real player

    private func applyPlaybackToPlayer(_ pb: PartyPlayback) {
        guard let wire = pb.track else {
            if !pb.isPlaying { PlayerEngine.shared.applyPartyPlayState(isPlaying: false, positionMs: Int(pb.positionMs), delayMs: 0) }
            return
        }
        let targetMs = clock.positionAt(pb)
        let delay = clock.leadDelayMs(for: pb)
        let player = PlayerEngine.shared
        if player.currentTrack?.id == wire.videoId {
            // Same song: only fix what actually differs (drift > 1.5 s, or play state).
            if player.isPlaying != pb.isPlaying || abs(player.position * 1000 - Double(targetMs)) > 1500 {
                player.applyPartyPlayState(isPlaying: pb.isPlaying, positionMs: Int(targetMs), delayMs: delay)
            }
        } else {
            let tracks = queue.map { $0.toTrack() }
            let idx = queue.firstIndex(of: wire) ?? pb.queueIndex
            player.applyPartyTrack(wire.toTrack(), queue: tracks.isEmpty ? [wire.toTrack()] : tracks, queueIndex: idx, positionMs: Int(targetMs), isPlaying: pb.isPlaying, delayMs: delay)
        }
    }
}

// MARK: - PartySyncDelegate: local gestures become control frames

extension ListenTogether: PartySyncDelegate {
    private func guardConnected() -> Bool {
        guard isInParty, connectionState == .connected || connectionState == .reconnecting else {
            lastServerError = "Not connected to a party server (tried \(lastAttemptedURL ?? serverBaseURL)). Your gesture was not sent."
            return false
        }
        return true
    }
    public func partyPlay(positionMs: Int) { guard guardConnected() else { return }; sendControl("play", ["positionMs": positionMs]) }
    public func partyPause(positionMs: Int) { guard guardConnected() else { return }; sendControl("pause", ["positionMs": positionMs]) }
    public func partySeek(positionMs: Int) { guard guardConnected() else { return }; sendControl("seek", ["positionMs": positionMs]) }
    public func partySetTrack(_ track: Track, positionMs: Int, isPlaying: Bool, queueIndex: Int?) {
        guard guardConnected() else { return }
        var extra: [String: Any] = ["track": PartyTrackWire.from(track).wireDict(), "positionMs": positionMs, "isPlaying": isPlaying]
        if let queueIndex { extra["queueIndex"] = queueIndex }
        sendControl("setTrack", extra)
    }
    public func partySetQueue(_ queue: [Track], queueIndex: Int) {
        guard guardConnected() else { return }
        // Server keeps at most 25 upcoming + the current track; trim locally first.
        let trimmed = Array(queue.prefix(max(0, queueIndex + 1) + Self.maxUpcoming))
        sendControl("setQueue", ["queue": trimmed.map { PartyTrackWire.from($0).wireDict() }, "queueIndex": queueIndex])
    }
    public func partyQueueAdd(_ tracks: [Track], playNext: Bool) {
        guard guardConnected() else { return }
        if isQueueFull { lastServerError = "Queue is full — at most 25 upcoming songs in a party."; return }
        sendControl("queueAdd", ["tracks": tracks.map { PartyTrackWire.from($0).wireDict() }, "playNext": playNext])
    }
    public func partyQueueRemove(videoId: String) { guard guardConnected() else { return }; sendControl("queueRemove", ["videoId": videoId]) }
    public func partyQueueClear() { guard guardConnected() else { return }; sendControl("queueClear") }
    public func partyQueueMove(from: Int, to: Int, videoId: String) {
        guard guardConnected() else { return }
        sendControl("queueMove", ["fromIndex": from, "toIndex": to, "videoId": videoId])
    }
    public func partyNext() { guard guardConnected() else { return }; sendControl("next") }
    public func partyPrevious() { guard guardConnected() else { return }; sendControl("previous") }
    public func partySetHostOnlyControl(_ enabled: Bool) {
        guard guardConnected() else { return }
        guard you?.isHost == true else {
            // The server would answer 403 host_only; surface it instead of silently dropping.
            lastServerError = "Only the host can change who controls the music."
            return
        }
        sendControl("setHostOnlyControl", ["enabled": enabled])
    }
    public func partyKick(memberId: String) {
        guard guardConnected() else { return }
        guard you?.isHost == true else { lastServerError = "Only the host can remove listeners."; return }
        sendControl("kick", ["memberId": memberId])
    }
}
