import Foundation
import MediaPlayer
import UniformTypeIdentifiers

// MARK: - Local library (port of LocalMediaRepository.kt)
// Two halves: the on-device Apple Music library (MPMediaQuery, needs the
// NSAppleMusicUsageDescription already in Info.plist) and files the user
// imports through the Files picker (copied into Documents/BitChord/Local).

@MainActor
public final class LocalLibrary: ObservableObject {
    public static let shared = LocalLibrary()
    @Published public var songs: [Track] = []
    @Published public var albums: [AlbumItem] = []
    @Published public var artists: [ArtistItem] = []
    @Published public var importedFiles: [Track] = []
    @Published public var authorizationStatus: MPMediaLibraryAuthorizationStatus = .notDetermined
    public enum SortOrder: String, CaseIterable { case title, artist, recent }
    @Published public var sortOrder: SortOrder = .title

    public var localDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("BitChord/Local")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private init() { refreshImported() }

    public func requestAuthorization() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in self?.authorizationStatus = status; if status == .authorized { self?.refresh() } }
        }
    }
    public func refresh() {
        guard MPMediaLibrary.authorizationStatus() == .authorized else { return }
        let query = MPMediaQuery.songs()
        var seenAlbums: [String: AlbumItem] = [:]
        var seenArtists: [String: ArtistItem] = [:]
        songs = (query.items ?? []).compactMap { item in
            guard let title = item.title else { return nil }
            let id = "local:\(item.persistentID)"
            if let albumTitle = item.albumTitle, seenAlbums[albumTitle] == nil {
                seenAlbums[albumTitle] = AlbumItem(id: "album:\(albumTitle)", title: albumTitle, artists: item.artist.map { [$0] } ?? [])
            }
            if let artist = item.artist, seenArtists[artist] == nil {
                seenArtists[artist] = ArtistItem(id: "artist:\(artist)", name: artist)
            }
            return Track(id: id, title: title, artists: item.artist.map { [$0] } ?? [], album: item.albumTitle, durationSeconds: item.playbackDuration, source: "local", localURL: item.assetURL)
        }
        albums = Array(seenAlbums.values); artists = Array(seenArtists.values)
        applySort()
    }
    public func applySort() {
        switch sortOrder {
        case .title: songs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: songs.sort { $0.artistText.localizedCaseInsensitiveCompare($1.artistText) == .orderedAscending }
        case .recent: break // MPMediaQuery order is the device's own order; keep it.
        }
    }
    public func refreshImported() {
        let exts = ["mp3", "m4a", "flac", "wav", "opus", "aac", "alac"]
        let files = (try? FileManager.default.contentsOfDirectory(at: localDirectory, includingPropertiesForKeys: nil)) ?? []
        importedFiles = files.filter { exts.contains($0.pathExtension.lowercased()) }.map { url in
            Track(id: "file:\(url.lastPathComponent)", title: url.deletingPathExtension().lastPathComponent, artists: [], durationSeconds: 0, source: "local", localURL: url)
        }.sorted { $0.title < $1.title }
    }
    /// Copy a picked file into the local folder (security-scoped access is
    /// honoured: the picker hands us a URL we may read once).
    public func importFile(_ url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let dest = localDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: url, to: dest)
            refreshImported(); return true
        } catch { return false }
    }
    public var allLocalTracks: [Track] { songs + importedFiles }
}
