import Foundation

// MARK: - Downloads (port of download/Downloads.kt + DownloadStore.kt)
// Files live in Documents/BitChord/Downloads; a manifest JSON beside them
// (DownloadManifestEntry) is what the Downloads screen reads, so a download
// survives a cold start and can be opened by a file manager.

@MainActor
public final class DownloadsStore: ObservableObject {
    public static let shared = DownloadsStore()
    @Published public private(set) var manifest: [DownloadManifestEntry] = []
    @Published public var progress: [String: Double] = [:]
    @Published public var activeDownloads: Set<String> = []
    private var tasks: [String: URLSessionDownloadTask] = [:]

    public var downloadsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BitChord/Downloads")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var manifestURL: URL { downloadsDirectory.appendingPathComponent("manifest.json") }

    private init() { loadManifest() }
    private func loadManifest() {
        if let data = try? Data(contentsOf: manifestURL), let decoded = try? JSONDecoder().decode([DownloadManifestEntry].self, from: data) {
            manifest = decoded.filter { FileManager.default.fileExists(atPath: downloadsDirectory.appendingPathComponent($0.fileName).path) }
        }
    }
    private func saveManifest() { try? JSONEncoder().encode(manifest).write(to: manifestURL) }
    public func localURL(for track: Track) -> URL? {
        guard let entry = manifest.first(where: { $0.id == track.id }) else { return nil }
        let url = downloadsDirectory.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    public func isDownloaded(_ track: Track) -> Bool { localURL(for: track) != nil }
    public func trackWithLocalURL(_ track: Track) -> Track {
        var t = track; t.localURL = localURL(for: track); return t
    }

    public func download(_ track: Track) {
        guard !isDownloaded(track), !activeDownloads.contains(track.id) else { return }
        activeDownloads.insert(track.id); progress[track.id] = 0
        Task {
            do {
                let format = try await StreamResolver.shared.resolveStreamURL(for: track, maxKbps: SettingsStore.shared.downloadQuality.maxKbps)
                guard let url = URL(string: format.url) else { throw StreamError.noFormats(videoId: track.id) }
                let ext = url.pathExtension.isEmpty ? (format.isOpus ? "opus" : "m4a") : url.pathExtension
                let fileName = "\(track.id).\(ext)"
                let dest = downloadsDirectory.appendingPathComponent(fileName)
                let task = URLSession.shared.downloadTask(with: url) { [weak self] temp, _, error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.activeDownloads.remove(track.id); self.progress.removeValue(forKey: track.id)
                        if let temp, error == nil {
                            try? FileManager.default.moveItem(at: temp, to: dest)
                            if FileManager.default.fileExists(atPath: dest.path) {
                                self.manifest.removeAll { $0.id == track.id }
                                self.manifest.append(DownloadManifestEntry(id: track.id, title: track.title, artists: track.artists, format: format.mimeType, date: Date(), fileName: fileName, durationSeconds: track.durationSeconds))
                                self.saveManifest()
                            }
                        }
                    }
                }
                tasks[track.id] = task
                // Progress observation via a delegate would need a session
                // delegate; the downloadTask completion above is the source
                // of truth, and progress is updated by polling the task.
                task.resume()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let t = tasks[track.id] else { break }
                    let p = Double(t.countOfBytesReceived) / Double(max(1, t.countOfBytesExpectedToReceive))
                    if p.isFinite { progress[track.id] = p }
                    if t.state == .completed { break }
                }
            } catch {
                activeDownloads.remove(track.id); progress.removeValue(forKey: track.id)
            }
        }
    }
    public func cancel(_ track: Track) {
        tasks[track.id]?.cancel(); tasks.removeValue(forKey: track.id)
        activeDownloads.remove(track.id); progress.removeValue(forKey: track.id)
    }
    public func delete(_ track: Track) {
        cancel(track)
        if let entry = manifest.first(where: { $0.id == track.id }) {
            try? FileManager.default.removeItem(at: downloadsDirectory.appendingPathComponent(entry.fileName))
            manifest.removeAll { $0.id == track.id }; saveManifest()
        }
    }
    public func downloadedTracks() -> [Track] {
        manifest.map { Track(id: $0.id, title: $0.title, artists: $0.artists, durationSeconds: $0.durationSeconds, source: "download", localURL: downloadsDirectory.appendingPathComponent($0.fileName)) }
    }
}
