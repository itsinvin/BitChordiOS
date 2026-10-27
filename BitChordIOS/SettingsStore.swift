import Foundation
import Combine
import Network
import UIKit

// MARK: - Settings (port of AppSettings.kt) + listening history + backup/restore.
// Tokens are NEVER here: Keychain.swift only. Settings are non-secret prefs.

public enum ThemeMode: String, CaseIterable, Codable { case system, light, dark }

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()
    private let defaults = UserDefaults.standard
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "bitchord.network")

    @Published public var wifiQuality: AudioQuality { didSet { defaults.set(wifiQuality.rawValue, forKey: "wifiQuality") } }
    @Published public var cellularQuality: AudioQuality { didSet { defaults.set(cellularQuality.rawValue, forKey: "cellularQuality") } }
    @Published public var downloadQuality: AudioQuality { didSet { defaults.set(downloadQuality.rawValue, forKey: "downloadQuality") } }
    @Published public var wifiOnlyDownloads: Bool { didSet { defaults.set(wifiOnlyDownloads, forKey: "wifiOnlyDownloads") } }
    @Published public var crossfadeSeconds: Double { didSet { defaults.set(crossfadeSeconds, forKey: "crossfadeSeconds") } }
    @Published public var automixEnabled: Bool { didSet { defaults.set(automixEnabled, forKey: "automixEnabled") } }
    @Published public var skipSilence: Bool { didSet { defaults.set(skipSilence, forKey: "skipSilence") } }
    @Published public var loudnessEnabled: Bool { didSet { defaults.set(loudnessEnabled, forKey: "loudnessEnabled") } }
    @Published public var themeMode: ThemeMode { didSet { defaults.set(themeMode.rawValue, forKey: "themeMode") } }
    @Published public var dynamicTheming: Bool { didSet { defaults.set(dynamicTheming, forKey: "dynamicTheming") } }
    @Published public var liquidGlass: Bool { didSet { defaults.set(liquidGlass, forKey: "liquidGlass") } }
    @Published public var animatedCanvas: Bool { didSet { defaults.set(animatedCanvas, forKey: "animatedCanvas") } }
    @Published public var canvasOverCellular: Bool { didSet { defaults.set(canvasOverCellular, forKey: "canvasOverCellular") } }
    @Published public var fullBleedArtwork: Bool { didSet { defaults.set(fullBleedArtwork, forKey: "fullBleedArtwork") } }
    @Published public var showNerdStats: Bool { didSet { defaults.set(showNerdStats, forKey: "showNerdStats") } }
    @Published public var autoplayEnabled: Bool { didSet { defaults.set(autoplayEnabled, forKey: "autoplayEnabled") } }
    @Published public var lyricsOffsetMs: Int { didSet { defaults.set(lyricsOffsetMs, forKey: "lyricsOffsetMs") } }
    @Published public var translationLanguage: String { didSet { defaults.set(translationLanguage, forKey: "translationLanguage") } }
    @Published public var lyricsProviderOrder: [String] { didSet { defaults.set(lyricsProviderOrder, forKey: "lyricsProviderOrder") } }
    @Published public var signatureAPIEnabled: Bool { didSet { defaults.set(signatureAPIEnabled, forKey: "signatureAPIEnabled") } }
    @Published public var signatureAPIURL: String { didSet { defaults.set(signatureAPIURL, forKey: "signatureAPIURL") } }
    @Published public var paxSenixAPIKey: String { didSet { Keychain.set(paxSenixAPIKey, for: "paxSenixApiKey") } }
    @Published public var isCellular: Bool = false
    @Published public var equalizerBands: [Double] { didSet { defaults.set(equalizerBands, forKey: "equalizerBands") } }
    @Published public var equalizerEnabled: Bool { didSet { defaults.set(equalizerEnabled, forKey: "equalizerEnabled") } }
    @Published public var equalizerBalance: Double { didSet { defaults.set(equalizerBalance, forKey: "equalizerBalance") } }

    private init() {
        wifiQuality = AudioQuality(rawValue: defaults.string(forKey: "wifiQuality") ?? "") ?? .lossless
        cellularQuality = AudioQuality(rawValue: defaults.string(forKey: "cellularQuality") ?? "") ?? .high
        downloadQuality = AudioQuality(rawValue: defaults.string(forKey: "downloadQuality") ?? "") ?? .high
        wifiOnlyDownloads = defaults.object(forKey: "wifiOnlyDownloads") as? Bool ?? true
        crossfadeSeconds = defaults.object(forKey: "crossfadeSeconds") as? Double ?? 0
        automixEnabled = defaults.object(forKey: "automixEnabled") as? Bool ?? false
        skipSilence = defaults.object(forKey: "skipSilence") as? Bool ?? false
        loudnessEnabled = defaults.object(forKey: "loudnessEnabled") as? Bool ?? false
        themeMode = ThemeMode(rawValue: defaults.string(forKey: "themeMode") ?? "") ?? .system
        dynamicTheming = defaults.object(forKey: "dynamicTheming") as? Bool ?? true
        liquidGlass = defaults.object(forKey: "liquidGlass") as? Bool ?? true
        animatedCanvas = defaults.object(forKey: "animatedCanvas") as? Bool ?? true
        canvasOverCellular = defaults.object(forKey: "canvasOverCellular") as? Bool ?? false
        fullBleedArtwork = defaults.object(forKey: "fullBleedArtwork") as? Bool ?? false
        showNerdStats = defaults.object(forKey: "showNerdStats") as? Bool ?? false
        autoplayEnabled = defaults.object(forKey: "autoplayEnabled") as? Bool ?? true
        lyricsOffsetMs = defaults.object(forKey: "lyricsOffsetMs") as? Int ?? 0
        translationLanguage = defaults.string(forKey: "translationLanguage") ?? "en"
        lyricsProviderOrder = defaults.stringArray(forKey: "lyricsProviderOrder") ?? ["LRCLIB", "LrcRed", "BiniLyrics", "LyricsPlus", "Unison", "PaxSenix", "Megalobiz", "KuGou"]
        signatureAPIEnabled = defaults.object(forKey: "signatureAPIEnabled") as? Bool ?? false
        signatureAPIURL = defaults.string(forKey: "signatureAPIURL") ?? ""
        paxSenixAPIKey = Keychain.get("paxSenixApiKey") ?? ""
        equalizerBands = defaults.array(forKey: "equalizerBands") as? [Double] ?? [0, 0, 0, 0, 0, 0, 0]
        equalizerEnabled = defaults.object(forKey: "equalizerEnabled") as? Bool ?? false
        equalizerBalance = defaults.object(forKey: "equalizerBalance") as? Double ?? 0
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isCellular = path.usesInterfaceType(.cellular) }
        }
        monitor.start(queue: monitorQueue)
    }

    public var currentMaxKbps: Int {
        (isCellular ? cellularQuality : wifiQuality).maxKbps
    }

    /// Push the stored prefs into the player engine (call on appear + on change).
    public func applyToPlayer() {
        let player = PlayerEngine.shared
        player.crossfadeSeconds = crossfadeSeconds
        player.automixEnabled = automixEnabled
        player.skipSilence = skipSilence
        player.autoplayEnabled = autoplayEnabled
        player.maxKbps = currentMaxKbps
    }

    // MARK: Backup / restore (JSON; tokens excluded on purpose)

    public struct Backup: Codable {
        public var settings: [String: String]
        public var history: [ListeningEntry]
        public var downloads: [DownloadManifestEntry]
    }
    public func exportBackup() -> Data? {
        let settings: [String: String] = [
            "wifiQuality": wifiQuality.rawValue, "cellularQuality": cellularQuality.rawValue,
            "downloadQuality": downloadQuality.rawValue, "crossfadeSeconds": "\(crossfadeSeconds)",
            "themeMode": themeMode.rawValue, "lyricsProviderOrder": lyricsProviderOrder.joined(separator: ","),
        ]
        let backup = Backup(settings: settings, history: HistoryStore.shared.entries, downloads: DownloadsStore.shared.manifest)
        return try? JSONEncoder().encode(backup)
    }
    public func importBackup(_ data: Data) {
        guard let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return }
        if let v = backup.settings["wifiQuality"], let q = AudioQuality(rawValue: v) { wifiQuality = q }
        if let v = backup.settings["cellularQuality"], let q = AudioQuality(rawValue: v) { cellularQuality = q }
        if let v = backup.settings["crossfadeSeconds"], let d = Double(v) { crossfadeSeconds = d }
        HistoryStore.shared.replace(with: backup.history)
        applyToPlayer()
    }
}

// MARK: - Listening history (port of ListeningRecorder / ListeningStats)

@MainActor
public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()
    @Published public private(set) var entries: [ListeningEntry] = []
    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ListeningHistory.json")
    }
    private init() {
        if let data = try? Data(contentsOf: fileURL), let decoded = try? JSONDecoder().decode([ListeningEntry].self, from: data) {
            entries = decoded
        }
    }
    public func record(track: Track, playedSeconds: Double) {
        guard playedSeconds >= 10 else { return }
        entries.append(ListeningEntry(trackId: track.id, title: track.title, artist: track.artistText, date: Date(), playedSeconds: playedSeconds, durationSeconds: track.durationSeconds))
        save()
    }
    public func replace(with newEntries: [ListeningEntry]) { entries = newEntries; save() }
    public func clear() { entries = []; save() }
    private func save() { try? JSONEncoder().encode(entries).write(to: fileURL) }
    public var totalMinutes: Double { entries.reduce(0) { $0 + $1.playedSeconds } / 60 }
    public var topTracks: [(title: String, artist: String, count: Int)] {
        var counts: [String: (String, String, Int)] = [:]
        for e in entries { let k = e.trackId; counts[k] = (e.title, e.artist, (counts[k]?.2 ?? 0) + 1) }
        return counts.values.sorted { $0.2 > $1.2 }.prefix(10).map { ($0.0, $0.1, $0.2) }
    }
    public var topArtists: [(artist: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries { counts[e.artist, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.prefix(10).map { ($0.key, $0.value) }
    }
}

// MARK: - Dominant colour from artwork (dynamic theming)

public extension UIImage {
    func dominantColor() -> UIColor {
        guard let cg = cgImage else { return .systemBackground }
        let width = 32, height = 32
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .systemBackground }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return .systemBackground }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var r = 0, g = 0, b = 0, n = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            let a = Int(pixels[i + 3]); if a < 32 { continue }
            r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2]); n += 1
        }
        guard n > 0 else { return .systemBackground }
        return UIColor(red: CGFloat(r / n) / 255, green: CGFloat(g / n) / 255, blue: CGFloat(b / n) / 255, alpha: 1)
    }
}
