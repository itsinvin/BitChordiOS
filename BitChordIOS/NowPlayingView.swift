import SwiftUI
import AVKit
import UIKit

// MARK: - Mini-player, full Now Playing, queue sheet, lyrics view, canvas

public struct AirPlayButton: UIViewRepresentable {
    public func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    public func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

public struct CanvasView: View {
    public var track: Track?
    @State private var phase = 0.0
    public var body: some View {
        ZStack {
            LinearGradient(colors: [.purple.opacity(0.6), .blue.opacity(0.5), .pink.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing)
            // Animated mesh-gradient stand-in: artwork video ("canvas") is
            // not part of the Innertube track model, so motion artwork is
            // rendered as animated blobs over the artwork colour field.
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                Circle().fill(.white.opacity(0.15)).frame(width: 220, height: 220)
                    .offset(x: sin(t * 0.3) * 60, y: cos(t * 0.23) * 40)
                Circle().fill(.yellow.opacity(0.12)).frame(width: 180, height: 180)
                    .offset(x: cos(t * 0.27) * 70, y: sin(t * 0.31) * 50)
            }
            if let track {
                ArtworkView(url: track.thumbnailURL, size: 200)
            }
        }
    }
}

public struct MiniPlayer: View {
    @StateObject private var player = PlayerEngine.shared
    @State private var showingNowPlaying = false
    public var body: some View {
        Group {
            if let track = player.currentTrack {
                HStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ArtworkView(url: track.thumbnailURL, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1).font(.subheadline)
                            Text(track.artistText).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onTapGesture { showingNowPlaying = true }
                    Spacer()
                    Button { player.togglePlayPause() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                }
                .padding(8)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .sheet(isPresented: $showingNowPlaying) { NowPlayingView() }
            }
        }
    }
}

public struct NowPlayingView: View {
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var showingQueue = false
    @State private var showingLyrics = false
    @State private var showingSleep = false
    @Environment(\.dismiss) private var dismiss
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if settings.animatedCanvas {
                        CanvasView(track: player.currentTrack).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 16))
                    } else if let track = player.currentTrack {
                        ArtworkView(url: track.thumbnailURL, size: 280)
                    }
                    if let track = player.currentTrack {
                        VStack(spacing: 4) {
                            Text(track.title).font(.title3).bold().multilineTextAlignment(.center)
                            Text(track.artistText).foregroundStyle(.secondary)
                            if let album = track.album { Text(album).font(.caption).foregroundStyle(.secondary) }
                        }
                    } else {
                        Text("Nothing playing").foregroundStyle(.secondary)
                    }
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...(max(player.duration, 1)))
                        HStack {
                            Text(formatTime(player.position)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(formatTime(player.duration)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 28) {
                        Button { player.shuffleEnabled.toggle() } label: { Image(systemName: "shuffle").foregroundStyle(player.shuffleEnabled ? Color.blue : Color.primary) }
                        Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title2) }
                        Button { player.togglePlayPause() } label: { Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 56)) }
                        Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2) }
                        Button {
                            player.repeatMode = player.repeatMode == .off ? .all : (player.repeatMode == .all ? .one : .off)
                        } label: { Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(player.repeatMode == .off ? Color.primary : Color.blue) }
                    }
                    HStack(spacing: 16) {
                        Menu("Speed \(player.playbackSpeed, specifier: "%.2g")×") {
                            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                                Button("\(speed, specifier: "%.2g")×") { player.setPlaybackSpeed(speed) }
                            }
                        }
                        Button("Queue") { showingQueue = true }
                        Button("Lyrics") { showingLyrics = true }
                        Button("Sleep") { showingSleep = true }
                        AirPlayButton().frame(width: 32, height: 32)
                    }
                    .font(.subheadline)
                    if let err = player.errorMessage { Text(err).foregroundStyle(.red).font(.callout) }
                    if settings.showNerdStats, let format = player.currentFormat {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stats for nerds").font(.headline)
                            Text("Codec: \(format.codec.isEmpty ? format.mimeType : format.codec)")
                            Text("Bitrate: \(format.kbps) kbps")
                            if let sr = format.sampleRate { Text("Sample rate: \(sr) Hz") }
                            Text("Duration: \(formatTime(player.duration)) · Speed: \(player.playbackSpeed, specifier: "%.2g")×")
                            Text("Crossfade: \(player.crossfadeSeconds, specifier: "%.0f")s · Automix: \(player.automixEnabled ? "on" : "off")")
                        }
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if player.isInParty {
                        Text("In a party — play, pause, seek and queue edits are sent to everyone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if showingLyrics, let track = player.currentTrack {
                        LyricsView(track: track)
                    }
                }
                .padding()
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showingQueue) { QueueSheet() }
            .alert("Sleep timer", isPresented: $showingSleep) {
                Button("15 min") { player.setSleepTimer(minutes: 15) }
                Button("30 min") { player.setSleepTimer(minutes: 30) }
                Button("45 min") { player.setSleepTimer(minutes: 45) }
                Button("60 min") { player.setSleepTimer(minutes: 60) }
                Button("Stop after this track") { player.setSleepAfterTrack() }
                Button("Cancel timer", role: .destructive) { player.cancelSleepTimer() }
                Button("Close", role: .cancel) {}
            } message: {
                if let remaining = player.sleepRemaining { Text("Sleeping in \(Int(remaining / 60)) min.") }
                else if player.sleepAfterTrack { Text("Playback stops after this track.") }
                else { Text("Pick a sleep timer.") }
            }
        }
    }
    private func formatTime(_ s: Double) -> String {
        let i = Int(s); return String(format: "%d:%02d", i / 60, i % 60)
    }
}

public struct QueueSheet: View {
    @StateObject private var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss
    public var body: some View {
        NavigationStack {
            List {
                if !player.playedHistory.isEmpty {
                    Section("History") {
                        ForEach(Array(player.playedHistory.reversed().enumerated()), id: \.offset) { _, track in
                            Text(track.title).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Up next") {
                    if player.currentIndex >= 0, player.currentIndex < player.queue.count {
                        let upcoming = Array(player.queue[(player.currentIndex + 1)...])
                        ForEach(Array(upcoming.enumerated()), id: \.offset) { offset, track in
                            HStack {
                                Text(track.title).lineLimit(1)
                                Spacer()
                                Text(track.artistText).font(.caption).foregroundStyle(.secondary)
                            }
                            .onTapGesture { player.playTrack(track, in: player.queue, at: player.currentIndex + 1 + offset) }
                        }
                        .onDelete { offsets in
                            for offset in offsets { player.removeFromQueue(videoId: upcoming[offset].id) }
                        }
                        .onMove { from, to in
                            // moveQueue works on full-queue indices.
                            for source in from {
                                let fromIndex = player.currentIndex + 1 + source
                                let toIndex = player.currentIndex + 1 + to
                                player.moveQueue(from: fromIndex, to: toIndex)
                            }
                        }
                    } else {
                        Text("Queue is empty.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Clear up next", role: .destructive) { player.clearUpcoming() }
                }
            }
            .navigationTitle("Queue")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

public struct LyricsView: View {
    public var track: Track
    @StateObject private var player = PlayerEngine.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var result: LyricsResult?
    @State private var translated: [LyricLine]?
    @State private var showingTranslation = false
    @State private var loading = false
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lyrics").font(.headline)
                Spacer()
                if let result { Text(result.provider).font(.caption).foregroundStyle(.secondary) }
                Button("Translate") {
                    Task {
                        if let result {
                            translated = await LyricsService.translate(lines: result.lines, to: settings.translationLanguage)
                            showingTranslation = true
                        }
                    }
                }
                Button("Share") { shareLyrics() }
            }
            if loading { ProgressView() }
            else if let result {
                let lines = showingTranslation ? (translated ?? result.lines) : result.lines
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                let active = result.lineIndex(at: player.position, offsetMs: settings.lyricsOffsetMs) == index
                                VStack(alignment: .leading, spacing: 2) {
                                    if line.words.isEmpty {
                                        Text(line.text)
                                            .font(active ? .title3.bold() : .body)
                                            .foregroundStyle(active ? .primary : .secondary)
                                    } else {
                                        HStack(spacing: 4) {
                                            ForEach(Array(line.words.enumerated()), id: \.offset) { wIndex, word in
                                                let wordActive = result.activeWord(in: line, at: player.position, offsetMs: settings.lyricsOffsetMs) == wIndex
                                                Text(word.text)
                                                    .font(wordActive ? .title3.bold() : .body)
                                                    .foregroundStyle(wordActive ? .primary : .secondary)
                                            }
                                        }
                                    }
                                    if showingTranslation, let translation = line.translation {
                                        Text(translation).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .id(index)
                                .onTapGesture { player.seek(to: line.time) }
                            }
                        }
                    }
                    .frame(height: 320)
                    .onChange(of: player.position) { _, _ in
                        if let active = result.lineIndex(at: player.position, offsetMs: settings.lyricsOffsetMs) {
                            withAnimation { proxy.scrollTo(active, anchor: .center) }
                        }
                    }
                }
                Stepper("Lyrics offset: \(settings.lyricsOffsetMs) ms", value: $settings.lyricsOffsetMs, in: -5000...5000, step: 250)
                    .font(.caption)
            } else {
                Text("No lyrics found from any provider.").foregroundStyle(.secondary)
            }
        }
        .task { await load() }
    }
    private func load() async {
        loading = true; defer { loading = false }
        result = await LyricsService.fetch(for: track)
    }
    private func shareLyrics() {
        guard let result else { return }
        let text = result.lines.map { $0.text }.joined(separator: "\n")
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 1350))
        let image = renderer.image { ctx in
            UIColor.black.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1080, height: 1350))
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: UIColor.white, .paragraphStyle: paragraph]
            let attributed = NSAttributedString(string: "\(track.title)\n\(track.artistText)\n\n\(text)", attributes: attrs)
            attributed.draw(in: CGRect(x: 60, y: 80, width: 960, height: 1190))
        }
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activity, animated: true)
        }
    }
}
