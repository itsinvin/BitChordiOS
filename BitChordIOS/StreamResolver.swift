import Foundation

// MARK: - Stream resolution (port of shared StreamResolver / InnerTubeXResolver)

public enum AudioQuality: String, CaseIterable, Codable {
    case lossless, high, medium, low
    /// Ceiling in kbps. Lossless = no ceiling (a module/JioSaavn source may serve FLAC).
    public var maxKbps: Int {
        switch self { case .lossless: return Int.max; case .high: return 320; case .medium: return 160; case .low: return 96 }
    }
    public var label: String {
        switch self { case .lossless: return "Lossless"; case .high: return "High"; case .medium: return "Medium"; case .low: return "Low" }
    }
}

public protocol StreamResolving {
    func resolveStreamURL(for track: Track, maxKbps: Int) async throws -> StreamFormat
}

public enum StreamError: LocalizedError {
    case requiresPoTokenOrCipher(videoId: String)
    case noFormats(videoId: String)
    case loginRequired(videoId: String)
    public var errorDescription: String? {
        switch self {
        case .requiresPoTokenOrCipher(let id):
            return "YouTube refused a direct stream URL for \(id): every format is signatureCipher-protected or requires a poToken. No URL was fabricated. Sign in via the Google account screen (which can mint a poToken) or play a downloaded/local copy."
        case .noFormats(let id): return "No playable stream formats were returned for \(id)."
        case .loginRequired(let id): return "YouTube requires sign-in to play \(id) (LOGIN_REQUIRED)."
        }
    }
}

public final class StreamResolver: StreamResolving {
    public static let shared = StreamResolver()
    /// Optional poToken, entered/minted via the account flow. Never hardcoded.
    public var poToken: String?
    private init() {}

    public func resolveStreamURL(for track: Track, maxKbps: Int) async throws -> StreamFormat {
        let json = try await InnertubeClient.shared.player(videoId: track.id)
        let status = json["playabilityStatus"]["status"].string ?? ""
        if status == "LOGIN_REQUIRED" { throw StreamError.loginRequired(videoId: track.id) }
        let streaming = json["streamingData"]
        var direct: [StreamFormat] = []
        var ciphered = 0
        for key in ["formats", "adaptiveFormats"] {
            for f in streaming[key].array ?? [] {
                if let url = f["url"].string, !url.isEmpty {
                    let mime = f["mimeType"].string ?? ""
                    direct.append(StreamFormat(url: url, mimeType: mime, bitrate: f["bitrate"].int ?? 0, sampleRate: f["audioSampleRate"].int, codec: mime))
                } else if !f["signatureCipher"].string.isNilOrEmpty {
                    ciphered += 1
                }
            }
        }
        // Per-network ceiling: Opus first (best quality per bit), then AAC.
        let underCeiling = direct.filter { $0.kbps <= maxKbps }
        let pool = underCeiling.isEmpty ? direct : underCeiling
        let opus = pool.filter { $0.isOpus }.sorted { $0.bitrate > $1.bitrate }
        let aac = pool.filter { $0.isAAC }.sorted { $0.bitrate > $1.bitrate }
        if let best = opus.first ?? aac.first ?? pool.sorted(by: { $0.bitrate > $1.bitrate }).first { return best }
        if ciphered > 0 { throw StreamError.requiresPoTokenOrCipher(videoId: track.id) }
        throw StreamError.noFormats(videoId: track.id)
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
