import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings, Equalizer, Replay (year-in-review)

public struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var player = PlayerEngine.shared
    @State private var backupData: Data?
    @State private var showingExporter = false
    @State private var showingImporter = false
    @State private var importMessage: String?
    public var body: some View {
        List {
            Section("Audio") {
                Picker("Quality on Wi-Fi", selection: $settings.wifiQuality) { ForEach(AudioQuality.allCases, id: \.self) { q in Text(q.label).tag(q) } }
                Picker("Quality on cellular", selection: $settings.cellularQuality) { ForEach(AudioQuality.allCases, id: \.self) { q in Text(q.label).tag(q) } }
                Picker("Download quality", selection: $settings.downloadQuality) { ForEach(AudioQuality.allCases, id: \.self) { q in Text(q.label).tag(q) } }
                Toggle("Wi-Fi only downloads", isOn: $settings.wifiOnlyDownloads)
                HStack {
                    Text("Crossfade")
                    Spacer()
                    Slider(value: $settings.crossfadeSeconds, in: 0...12, step: 1).frame(width: 160)
                    Text("\(Int(settings.crossfadeSeconds))s").font(.caption)
                }
                Toggle("Automix (Beta)", isOn: $settings.automixEnabled)
                Toggle("Skip silence (trailing silence only)", isOn: $settings.skipSilence)
                Toggle("Loudness normalization", isOn: $settings.loudnessEnabled)
                Toggle("Autoplay", isOn: $settings.autoplayEnabled)
                Text("Dolby Atmos / spatial audio: iOS does not expose a per-app Atmos switch for AVPlayer streams — tracks that carry spatial audio play through the system audio session as delivered.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Playback") {
                Toggle("Show stats for nerds", isOn: $settings.showNerdStats)
                if let remaining = player.sleepRemaining {
                    Text("Sleep timer: \(Int(remaining / 60)) min remaining")
                }
                Button("Cancel sleep timer") { player.cancelSleepTimer() }
            }
            Section("Appearance") {
                Picker("Theme", selection: $settings.themeMode) { ForEach(ThemeMode.allCases, id: \.self) { m in Text(m.rawValue.capitalized).tag(m) } }
                Toggle("Dynamic artwork theming", isOn: $settings.dynamicTheming)
                Toggle("Frosted / liquid glass UI", isOn: $settings.liquidGlass)
                Toggle("Animated canvas", isOn: $settings.animatedCanvas)
                Toggle("Canvas over cellular", isOn: $settings.canvasOverCellular)
                Toggle("Full-bleed artwork", isOn: $settings.fullBleedArtwork)
            }
            Section("Lyrics") {
                Stepper("Offset: \(settings.lyricsOffsetMs) ms", value: $settings.lyricsOffsetMs, in: -5000...5000, step: 250)
                TextField("Translation language code (e.g. es, fr, ja)", text: $settings.translationLanguage)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                NavigationLink("Lyrics provider order") { LyricsProviderOrderView() }
                SecureField("PaxSenix API key (optional)", text: $settings.paxSenixAPIKey)
            }
            Section("Signature API") {
                Toggle("Enable signature API", isOn: $settings.signatureAPIEnabled)
                TextField("Signature API URL", text: $settings.signatureAPIURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Stored as a setting only; it is not used to fetch streams unless a future source needs it.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Equalizer") {
                NavigationLink("Open equalizer") { EqualizerView() }
            }
            Section("Replay") {
                NavigationLink("Your Replay") { ReplayView() }
            }
            Section("Accounts & sources") {
                NavigationLink("Accounts") { AccountsView() }
                NavigationLink("Sources") { SourcesView() }
                NavigationLink("Listen Together") { ListenTogetherView() }
            }
            Section("Backup & restore") {
                Button("Export backup (JSON)") { backupData = settings.exportBackup(); showingExporter = backupData != nil }
                Button("Import backup") { showingImporter = true }
                if let msg = importMessage { Text(msg).font(.caption) }
                Text("Backup contains settings, listening history and the download manifest — never tokens.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .onChange(of: settings.crossfadeSeconds) { _, _ in settings.applyToPlayer() }
        .onChange(of: settings.automixEnabled) { _, _ in settings.applyToPlayer() }
        .onChange(of: settings.skipSilence) { _, _ in settings.applyToPlayer(); player.refreshEqualizer() }
        .onChange(of: settings.autoplayEnabled) { _, _ in settings.applyToPlayer() }
        .onChange(of: settings.isCellular) { _, _ in settings.applyToPlayer() }
        .onAppear { settings.applyToPlayer() }
        .fileExporter(isPresented: $showingExporter, document: BackupDocument(data: backupData ?? Data()), contentType: .json, defaultFilename: "bitchord-backup") { _ in }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result, let data = try? Data(contentsOf: url) {
                settings.importBackup(data); importMessage = "Backup imported."
            } else { importMessage = "Could not read that backup file." }
        }
    }
}

public struct BackupDocument: FileDocument {
    public var data: Data
    public init(data: Data) { self.data = data }
    public static var readableContentTypes: [UTType] { [.json] }
    public init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

public struct LyricsProviderOrderView: View {
    @StateObject private var settings = SettingsStore.shared
    public var body: some View {
        List {
            ForEach(settings.lyricsProviderOrder, id: \.self) { provider in Text(provider) }
                .onMove { from, to in
                    var order = settings.lyricsProviderOrder
                    order.move(fromOffsets: from, toOffset: to)
                    settings.lyricsProviderOrder = order
                }
            Text("LRCLIB is key-less and tried first by default. KuGou returns KRC lyrics, which this port does not decode — it falls through to the next provider.").font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Lyrics providers")
        .toolbar { EditButton() }
    }
}

public struct EqualizerView: View {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var player = PlayerEngine.shared
    public var body: some View {
        List {
            Section {
                Toggle("Equalizer", isOn: $settings.equalizerEnabled)
                    .onChange(of: settings.equalizerEnabled) { _, _ in apply() }
                Picker("Preset", selection: Binding(
                    get: { EqualizerPreset.matching(settings.equalizerBands) },
                    set: { preset in if let bands = preset.bands { settings.equalizerBands = bands; apply() } }
                )) { ForEach(EqualizerPreset.allCases, id: \.self) { p in Text(p.rawValue).tag(p) } }
                HStack {
                    Text("Balance")
                    Spacer()
                    Slider(value: $settings.equalizerBalance, in: -1...1, step: 0.1)
                        .frame(width: 180)
                        .onChange(of: settings.equalizerBalance) { _, _ in apply() }
                    Text(String(format: "%.1f", settings.equalizerBalance)).font(.caption)
                }
                Toggle("Loudness normalization", isOn: $settings.loudnessEnabled)
            }
            Section("Bands (±12 dB)") {
                ForEach(Array(eqFrequencies.enumerated()), id: \.offset) { index, freq in
                    HStack {
                        Text(freq >= 1000 ? String(format: "%.1f kHz", freq / 1000) : "\(Int(freq)) Hz").frame(width: 70, alignment: .leading)
                        Slider(value: Binding(get: { settings.equalizerBands.indices.contains(index) ? settings.equalizerBands[index] : 0 }, set: { newValue in
                            if settings.equalizerBands.indices.contains(index) { settings.equalizerBands[index] = newValue; apply() }
                        }), in: -12...12, step: 0.5)
                        Text(String(format: "%+.1f", settings.equalizerBands.indices.contains(index) ? settings.equalizerBands[index] : 0)).font(.caption).frame(width: 44)
                    }
                }
                Text("First band is a low shelf, last a high shelf, the rest peaking — same curve as the original. Boost headroom is taken back by a preamp cut so boosted bands do not clip.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Equalizer")
        .onAppear { syncFromPlayer() }
    }
    private func apply() {
        player.equalizerEnabled = settings.equalizerEnabled
        player.equalizerBands = settings.equalizerBands
        player.equalizerBalance = settings.equalizerBalance
        player.refreshEqualizer()
    }
    private func syncFromPlayer() {
        if player.equalizerBands != settings.equalizerBands, player.equalizerEnabled {
            settings.equalizerBands = player.equalizerBands
        }
    }
}

public struct ReplayView: View {
    @StateObject private var history = HistoryStore.shared
    public var body: some View {
        List {
            Section("Your Replay") {
                Text("Total listening: \(Int(history.totalMinutes)) minutes")
                Text("Tracks played: \(history.entries.count)")
            }
            Section("Top tracks") {
                ForEach(Array(history.topTracks.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading) {
                        Text(item.title)
                        Text("\(item.artist) · \(item.count) plays").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Top artists") {
                ForEach(Array(history.topArtists.enumerated()), id: \.offset) { _, item in
                    HStack { Text(item.artist); Spacer(); Text("\(item.count) plays").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                ShareLink("Share my Replay", item: replayText())
            }
        }
        .navigationTitle("Replay")
    }
    private func replayText() -> String {
        var lines = ["My BitChord Replay", "\(Int(history.totalMinutes)) minutes listened", "", "Top tracks:"]
        for t in history.topTracks.prefix(5) { lines.append("• \(t.title) — \(t.artist) (\(t.count) plays)") }
        lines.append(""); lines.append("Top artists:")
        for a in history.topArtists.prefix(5) { lines.append("• \(a.artist) (\(a.count) plays)") }
        return lines.joined(separator: "\n")
    }
}
