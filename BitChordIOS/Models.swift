import Foundation

// MARK: - Core catalogue models (port of shared Models.kt / InnertubeParser.kt)

public struct Track: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String?
    public var albumId: String?
    public var thumbnailURL: String?
    public var durationSeconds: Double
    public var videoId: String { id }
    public var isExplicit: Bool = false
    public var source: String = "youtube"
    public var localURL: URL?
    public init(id: String, title: String, artists: [String] = [], album: String? = nil, albumId: String? = nil, thumbnailURL: String? = nil, durationSeconds: Double = 0, isExplicit: Bool = false, source: String = "youtube", localURL: URL? = nil) {
        self.id = id; self.title = title; self.artists = artists; self.album = album; self.albumId = albumId
        self.thumbnailURL = thumbnailURL; self.durationSeconds = durationSeconds; self.isExplicit = isExplicit; self.source = source; self.localURL = localURL
    }
    public var artistText: String { artists.joined(separator: ", ") }
    public var durationText: String {
        let s = Int(durationSeconds); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

public struct ArtistItem: Identifiable, Codable, Equatable {
    public var id: String; public var name: String; public var thumbnailURL: String?; public var subscriberText: String?
    public init(id: String, name: String, thumbnailURL: String? = nil, subscriberText: String? = nil) { self.id = id; self.name = name; self.thumbnailURL = thumbnailURL; self.subscriberText = subscriberText }
}

public struct AlbumItem: Identifiable, Codable, Equatable {
    public var id: String; public var title: String; public var artists: [String]; public var thumbnailURL: String?; public var year: String?
    public init(id: String, title: String, artists: [String] = [], thumbnailURL: String? = nil, year: String? = nil) { self.id = id; self.title = title; self.artists = artists; self.thumbnailURL = thumbnailURL; self.year = year }
}

public struct PlaylistItem: Identifiable, Codable, Equatable {
    public var id: String; public var title: String; public var author: String?; public var thumbnailURL: String?; public var trackCount: Int?
    public init(id: String, title: String, author: String? = nil, thumbnailURL: String? = nil, trackCount: Int? = nil) { self.id = id; self.title = title; self.author = author; self.thumbnailURL = thumbnailURL; self.trackCount = trackCount }
}

public struct Shelf: Identifiable, Equatable {
    public var id = UUID(); public var title: String; public var tracks: [Track]; public var items: [ShelfItem]
    public init(title: String, tracks: [Track] = [], items: [ShelfItem] = []) { self.title = title; self.tracks = tracks; self.items = items }
}

public enum ShelfItem: Equatable {
    case track(Track); case artist(ArtistItem); case album(AlbumItem); case playlist(PlaylistItem)
}

public enum SearchFilter: String, CaseIterable, Identifiable {
    case all = "All"; case songs = "Songs"; case albums = "Albums"; case artists = "Artists"; case playlists = "Playlists"
    public var id: String { rawValue }
    /// Innertube search params used by the original (EgWKAQI* family). Kept as
    /// the documented filter values; the client sends them verbatim.
    public var innertubeParams: String? {
        switch self {
        case .all: return nil
        case .songs: return "EgWKAQIIAWoKEA"
        case .albums: return "EgWKAQIYAWoKEA"
        case .artists: return "EgWKAQJBAWoKEA"
        case .playlists: return "EgWKAQJAAWoKEA"
        }
    }
}

public struct StreamFormat: Equatable {
    public var url: String; public var mimeType: String; public var bitrate: Int; public var sampleRate: Int?; public var codec: String
    public var isOpus: Bool { mimeType.contains("opus") }
    public var isAAC: Bool { mimeType.contains("mp4") }
    public init(url: String, mimeType: String, bitrate: Int, sampleRate: Int? = nil, codec: String = "") { self.url = url; self.mimeType = mimeType; self.bitrate = bitrate; self.sampleRate = sampleRate; self.codec = codec }
    public var kbps: Int { bitrate / 1000 }
}

public enum RepeatMode: String, CaseIterable, Codable { case off, all, one }

public struct ListeningEntry: Codable, Equatable {
    public var trackId: String; public var title: String; public var artist: String; public var date: Date; public var playedSeconds: Double; public var durationSeconds: Double
}

public struct DownloadManifestEntry: Codable, Equatable {
    public var id: String; public var title: String; public var artists: [String]; public var format: String; public var date: Date; public var fileName: String; public var durationSeconds: Double
}

extension String {
    public func htmlUnescaped() -> String {
        var s = self
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&lt;": "<", "&gt;": ">"] { s = s.replacingOccurrences(of: k, with: v) }
        return s
    }
}
