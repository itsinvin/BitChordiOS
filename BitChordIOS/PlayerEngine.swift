import Foundation
import AVFoundation
import Combine
import MediaPlayer
import UIKit

// MARK: - Party -> player contract.
// PlayerEngine never knows about HTTP or WebSockets; it only reports local
// gestures to its party delegate and applies remote state without echoing it.

public protocol PartySyncDelegate: AnyObject {
    func partyPlay(positionMs: Int)
    func partyPause(positionMs: Int)
    func partySeek(positionMs: Int)
    func partySetTrack(_ track: Track, positionMs: Int, isPlaying: Bool, queueIndex: Int?)
    func partySetQueue(_ queue: [Track], queueIndex: Int)
    func partyQueueAdd(_ tracks: [Track], playNext: Bool)
    func partyQueueRemove(videoId: String)
    func partyQueueClear()
    func partyQueueMove(from: Int, to: Int, videoId: String)
    func partyNext()
    func partyPrevious()
    func partySetHostOnlyControl(_ enabled: Bool)
}

/// Real playback engine: one AVPlayer, background audio session, local files
/// first, then StreamResolver for remote tracks. Crossfade/Automix/EQ live in
/// their own files and wrap this player's item; this file is the party wiring.
public final class PlayerEngine: ObservableObject {
    public static let shared = PlayerEngine()
    @Published public private(set) var queue: [Track] = []
    @Published public private(set) var currentIndex: Int = -1
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public var errorMessage: String?
    @Published public var playbackSpeed: Double = 1.0
    // Player upgrades (party contract above is untouched).
    @Published public var shuffleEnabled: Bool = false
    @Published public var repeatMode: RepeatMode = .off
    @Published public var crossfadeSeconds: Double = 0
    @Published public var automixEnabled: Bool = false
    @Published public var skipSilence: Bool = false
    @Published public var autoplayEnabled: Bool = true
    @Published public var currentFormat: StreamFormat?
    @Published public var playedHistory: [Track] = []
    @Published public var sleepRemaining: Double?
    @Published public var sleepAfterTrack: Bool = false
    public var equalizerBands: [Double] = [0, 0, 0, 0, 0, 0, 0]
    public var equalizerEnabled: Bool = false
    public var equalizerBalance: Double = 0
    private var sleepEnd: Date?
    private var fadePlayer: AVPlayer?
    private var fadeTimer: Timer?
    private var fadeTargetIndex: Int?
    private var fadeOverlap: Double = 0
    private var fadeElapsed: Double = 0
    private var fadeRate: Double = 1
    private var crossfadeSourceId: String?
    private var silentTicks: Int = 0
    private var nowPlayingArtworkTrackId: String?
    public weak var partyDelegate: PartySyncDelegate?
    /// Party delegate methods live on @MainActor ListenTogether; hop there
    /// instead of calling them synchronously from this non-isolated engine.
    private func notifyParty(_ action: @MainActor @escaping (PartySyncDelegate) -> Void) {
        guard let delegate = partyDelegate, !applyingPartyState else { return }
        Task { @MainActor in action(delegate) }
    }
    public var isInParty: Bool { partyDelegate != nil }
    /// True while a remote party state is being applied; suppresses echo frames.
    public var applyingPartyState: Bool = false
    public var streamResolver: StreamResolving = StreamResolver.shared
    public var maxKbps: Int = AudioQuality.lossless.maxKbps

    public var currentTrack: Track? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }
    private var player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    private init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        attachTimeObserver()
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            // Only the active player's item ending counts: the crossfade
            // player's item ending must not advance the queue a second time.
            if let item = notification.object as? AVPlayerItem, item != self.player.currentItem { return }
            if self.sleepAfterTrack { self.sleepAfterTrack = false; self.sleepRemaining = nil; self.pause(); return }
            if self.isInParty { self.notifyParty { $0.partyNext() } } else { self.next() }
        }
        setupRemoteCommands()
    }
    private var observedPlayer: AVPlayer?
    private func attachTimeObserver() {
        if let token = timeObserver, let observed = observedPlayer { observed.removeTimeObserver(token) }
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            self?.position = t.seconds.isFinite ? t.seconds : 0
            self?.handleTick()
        }
    }
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
    }
    private func updateNowPlaying() {
        guard let track = currentTrack else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artistText,
            MPMediaItemPropertyAlbumTitle: track.album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? playbackSpeed : 0,
        ]
        if let artwork = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private func fetchNowPlayingArtwork(for track: Track) {
        guard let urlString = track.thumbnailURL, let url = URL(string: urlString), nowPlayingArtworkTrackId != track.id else { return }
        nowPlayingArtworkTrackId = track.id
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
            await MainActor.run {
                if self.currentTrack?.id == track.id {
                    self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.updateNowPlaying()
                }
            }
        }
    }
    private func recordHistory(track: Track, played: Double) {
        Task { @MainActor in HistoryStore.shared.record(track: track, playedSeconds: played) }
    }
    private func handleTick() {
        updateNowPlaying()
        if let end = sleepEnd {
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 { sleepEnd = nil; sleepRemaining = nil; pause(); return }
            sleepRemaining = remaining
        }
        if let track = currentTrack {
            Task { await Scrobbler.maybeScrobble(track: track, playedSeconds: position) }
        }
        // Skip silence, honestly scoped: the EQ/silence tap measures RMS of
        // the decoded stream. Only a silent TAIL is skipped (2 s of near
        // silence inside the last 20 s) — a silent intro cannot be skipped
        // without offline analysis, and this code does not pretend otherwise.
        if skipSilence, duration > 20, position > duration - 20, position > 10 {
            if SilenceMonitor.shared.rms < 0.0005 { silentTicks += 1 } else { silentTicks = 0 }
            if silentTicks >= 4 { silentTicks = 0; next(); return }
        } else { silentTicks = 0 }
        // Crossfade is disabled in a party (it would desync the shared clock)
        // and when "stop after this track" is set.
        guard !isInParty, !sleepAfterTrack, isPlaying, duration > 0 else { return }
        let overlap = effectiveOverlap()
        guard overlap > 0, position >= duration - overlap else {
            if position < duration - overlap - 1 { cancelCrossfade(restoreVolume: true) }
            return
        }
        if crossfadeSourceId != currentTrack?.id, let idx = nextIndexForCrossfade() {
            startCrossfade(to: idx, overlap: overlap)
        }
    }
    private func effectiveOverlap() -> Double {
        guard automixEnabled, let current = currentTrack, let idx = nextIndexForCrossfade(), queue.indices.contains(idx) else { return crossfadeSeconds }
        let plan = Automix.plan(outgoingBPM: Automix.bpmCache[current.id], incomingBPM: Automix.bpmCache[queue[idx].id], crossfadeSeconds: crossfadeSeconds)
        return plan.overlapSeconds
    }
    private func nextIndexForCrossfade() -> Int? {
        if repeatMode == .one { return nil }
        return nextIndex()
    }
    public func nextIndex() -> Int? {
        if repeatMode == .one { return currentIndex }
        if shuffleEnabled, queue.count > 1 {
            let candidates = queue.indices.filter { $0 != currentIndex }
            return candidates.randomElement()
        }
        if currentIndex + 1 < queue.count { return currentIndex + 1 }
        if repeatMode == .all, !queue.isEmpty { return 0 }
        return nil
    }
    private func cancelCrossfade(restoreVolume: Bool) {
        fadeTimer?.invalidate(); fadeTimer = nil
        fadePlayer?.pause(); fadePlayer = nil; fadeTargetIndex = nil; crossfadeSourceId = nil
        if restoreVolume { player.volume = 1 }
    }
    private func startCrossfade(to index: Int, overlap: Double) {
        guard let source = currentTrack, queue.indices.contains(index) else { return }
        crossfadeSourceId = source.id; fadeTargetIndex = index; fadeOverlap = overlap; fadeElapsed = 0
        let target = queue[index]
        var rate = playbackSpeed
        if automixEnabled {
            let plan = Automix.plan(outgoingBPM: Automix.bpmCache[source.id], incomingBPM: Automix.bpmCache[target.id], crossfadeSeconds: crossfadeSeconds)
            if plan.beatMatched { rate = plan.incomingRate }
        }
        fadeRate = rate
        Task {
            let item: AVPlayerItem?
            if let local = target.localURL, FileManager.default.fileExists(atPath: local.path) {
                item = AVPlayerItem(url: local)
            } else {
                do {
                    let format = try await streamResolver.resolveStreamURL(for: target, maxKbps: maxKbps)
                    guard let url = URL(string: format.url) else { return }
                    item = AVPlayerItem(url: url)
                } catch { return }
            }
            await MainActor.run {
                guard let item, self.crossfadeSourceId == source.id else { return }
                item.audioMix = self.audioMixForCurrentSettings()
                let next = AVPlayer(playerItem: item)
                next.volume = 0; next.rate = Float(rate); next.play()
                self.fadePlayer = next
                self.fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.fadeStep() }
            }
        }
    }
    private func fadeStep() {
        guard let incomingPlayer = fadePlayer, let targetIndex = fadeTargetIndex else { cancelCrossfade(restoreVolume: true); return }
        fadeElapsed += 0.1
        let t = min(1, fadeElapsed / max(0.1, fadeOverlap))
        let gains = automixEnabled ? Automix.gains(at: t) : (outgoing: 1 - t, incoming: t)
        player.volume = Float(gains.outgoing)
        incomingPlayer.volume = Float(gains.incoming)
        if t >= 1 {
            fadeTimer?.invalidate(); fadeTimer = nil
            let oldTrack = currentTrack
            if let oldTrack { recordHistory(track: oldTrack, played: oldTrack.durationSeconds) }
            if let oldTrack, !playedHistory.contains(oldTrack) { playedHistory.append(oldTrack) }
            let oldPlayer = player
            player = incomingPlayer; fadePlayer = nil; fadeTargetIndex = nil; crossfadeSourceId = nil
            oldPlayer.pause()
            currentIndex = targetIndex
            player.volume = 1
            attachTimeObserver()
            position = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
            isPlaying = true
            if let track = currentTrack { fetchNowPlayingArtwork(for: track) }
        }
    }
    public func audioMixForCurrentSettings() -> AVAudioMix? {
        guard equalizerEnabled || skipSilence else { return nil }
        return EqualizerTap.audioMix(bands: equalizerEnabled ? equalizerBands : [0, 0, 0, 0, 0, 0, 0], balance: equalizerBalance, force: skipSilence)
    }
    public func refreshEqualizer() {
        player.currentItem?.audioMix = audioMixForCurrentSettings()
        fadePlayer?.currentItem?.audioMix = audioMixForCurrentSettings()
    }
    public func setSleepTimer(minutes: Double?) {
        if let minutes { sleepEnd = Date().addingTimeInterval(minutes * 60); sleepRemaining = minutes * 60; sleepAfterTrack = false }
        else { sleepEnd = nil; sleepRemaining = nil }
    }
    public func setSleepAfterTrack() { sleepAfterTrack = true; sleepEnd = nil; sleepRemaining = nil }
    public func cancelSleepTimer() { sleepEnd = nil; sleepRemaining = nil; sleepAfterTrack = false }
    public func fetchAutoplay() async {
        guard let track = currentTrack else { return }
        do {
            let json = try await InnertubeClient.shared.next(videoId: track.id)
            let tracks = InnertubeClient.parseTracks(from: json).filter { $0.id != track.id }
            if !tracks.isEmpty {
                await MainActor.run { self.queue.append(contentsOf: tracks) }
            }
        } catch { /* autoplay is best-effort; an empty queue is not an error */ }
    }

    // MARK: - Local gestures (report to party when in one, unless applying)

    public func play() {
        player.play(); player.rate = Float(playbackSpeed); isPlaying = true
        notifyParty { $0.partyPlay(positionMs: Int(self.position * 1000)) }
    }
    public func pause() {
        player.pause(); isPlaying = false
        notifyParty { $0.partyPause(positionMs: Int(self.position * 1000)) }
    }
    public func togglePlayPause() { isPlaying ? pause() : play() }
    public func seek(to seconds: Double) {
        let target = max(0, seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        position = target
        notifyParty { $0.partySeek(positionMs: Int(target * 1000)) }
    }
    public func setPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        if isPlaying { player.rate = Float(speed) }
    }

    public func playTrack(_ track: Track, in newQueue: [Track]? = nil, at index: Int? = nil, startPosition: Double = 0) {
        if let old = currentTrack, old.id != track.id, position >= 10 { recordHistory(track: old, played: position); playedHistory.append(old) }
        if let newQueue { setQueueInternal(newQueue, index: index ?? newQueue.firstIndex(of: track) ?? 0, reportToParty: true) }
        else if let index { setQueueInternal(queue, index: index, reportToParty: false) }
        else if !queue.contains(track) { setQueueInternal(queue + [track], index: queue.count, reportToParty: true) }
        else { setQueueInternal(queue, index: queue.firstIndex(of: track) ?? currentIndex, reportToParty: false) }
        Task { await loadCurrentTrack(startPosition: startPosition, autoplay: true) }
    }
    public func setQueue(_ newQueue: [Track], index: Int) {
        setQueueInternal(newQueue, index: index, reportToParty: true)
        Task { await loadCurrentTrack(startPosition: 0, autoplay: isPlaying) }
    }
    private func setQueueInternal(_ newQueue: [Track], index: Int, reportToParty: Bool) {
        queue = newQueue; currentIndex = newQueue.indices.contains(index) ? index : (newQueue.isEmpty ? -1 : 0)
        if reportToParty { notifyParty { $0.partySetQueue(newQueue, queueIndex: self.currentIndex) } }
    }
    public func next() {
        if isInParty { notifyParty { $0.partyNext() }; return }
        cancelCrossfade(restoreVolume: true)
        if repeatMode == .one { seek(to: 0); play(); return }
        if let idx = nextIndex() {
            if let old = currentTrack { recordHistory(track: old, played: position); playedHistory.append(old) }
            currentIndex = idx; Task { await loadCurrentTrack(startPosition: 0, autoplay: true) }
            return
        }
        // Queue exhausted: autoplay asks /next for related tracks.
        if autoplayEnabled {
            Task {
                let before = queue.count
                await fetchAutoplay()
                await MainActor.run {
                    if self.queue.count > before { self.currentIndex = before; Task { await self.loadCurrentTrack(startPosition: 0, autoplay: true) } }
                }
            }
        }
    }
    public func previous() {
        if isInParty { notifyParty { $0.partyPrevious() }; return }
        cancelCrossfade(restoreVolume: true)
        if position > 3 { seek(to: 0); return }
        if currentIndex > 0 { currentIndex -= 1; Task { await loadCurrentTrack(startPosition: 0, autoplay: true) } }
        else if repeatMode == .all, !queue.isEmpty { currentIndex = queue.count - 1; Task { await loadCurrentTrack(startPosition: 0, autoplay: true) } }
        else { seek(to: 0) }
    }
    public func addToQueue(_ tracks: [Track], playNext: Bool = false) {
        if isInParty { notifyParty { $0.partyQueueAdd(tracks, playNext: playNext) }; return }
        if playNext, currentIndex >= 0 { queue.insert(contentsOf: tracks, at: currentIndex + 1) }
        else { queue.append(contentsOf: tracks) }
    }
    public func removeFromQueue(videoId: String) {
        if isInParty { notifyParty { $0.partyQueueRemove(videoId: videoId) }; return }
        queue.removeAll { $0.id == videoId }
        if currentIndex >= queue.count { currentIndex = queue.count - 1 }
    }
    public func clearUpcoming() {
        if isInParty { notifyParty { $0.partyQueueClear() }; return }
        if currentIndex >= 0, currentIndex + 1 < queue.count { queue.removeSubrange((currentIndex + 1)...) }
    }
    public func moveQueue(from: Int, to: Int) {
        guard queue.indices.contains(from), queue.indices.contains(to), from != to else { return }
        if isInParty { let vid = queue[from].id; notifyParty { $0.partyQueueMove(from: from, to: to, videoId: vid) }; return }
        let item = queue.remove(at: from); queue.insert(item, at: to)
        if currentIndex == from { currentIndex = to }
    }

    // MARK: - Loading (local file wins; remote resolves its own URL per device)

    public func loadCurrentTrack(startPosition: Double, autoplay: Bool) async {
        guard let track = currentTrack else { return }
        errorMessage = nil; duration = track.durationSeconds
        cancelCrossfade(restoreVolume: false)
        player.volume = 1
        let item: AVPlayerItem?
        if let local = track.localURL, FileManager.default.fileExists(atPath: local.path) {
            item = AVPlayerItem(url: local)
            await MainActor.run { self.currentFormat = StreamFormat(url: local.absoluteString, mimeType: "audio/\(local.pathExtension)", bitrate: 0, codec: local.pathExtension.uppercased()) }
            Task { if let bpm = await Automix.estimateBPM(for: local) { Automix.bpmCache[track.id] = bpm } }
        } else {
            // Pluggable sources first (SourceRegistry order), YouTube last.
            var resolved: StreamFormat?
            do {
                if let viaSource = await SourceRegistry.shared.resolve(track: track) { resolved = viaSource }
                else { resolved = try await streamResolver.resolveStreamURL(for: track, maxKbps: maxKbps) }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription; self.isPlaying = false }
                return
            }
            guard let format = resolved, let url = URL(string: format.url) else {
                await MainActor.run { self.errorMessage = StreamError.noFormats(videoId: track.id).localizedDescription; self.isPlaying = false }
                return
            }
            await MainActor.run { self.currentFormat = format }
            item = AVPlayerItem(url: url)
        }
        item?.audioMix = audioMixForCurrentSettings()
        await MainActor.run {
            self.player.replaceCurrentItem(with: item)
            if startPosition > 0 { self.player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600)); self.position = startPosition }
            if autoplay { self.player.play(); self.player.rate = Float(self.playbackSpeed); self.isPlaying = true }
            else { self.player.pause(); self.isPlaying = false }
            self.fetchNowPlayingArtwork(for: track)
            self.updateNowPlaying()
        }
        Task { await Scrobbler.nowPlaying(track: track) }
        Task { @MainActor in DiscordPresence.shared.update(track: track, position: startPosition, isPlaying: autoplay, quality: currentFormat.map { "\($0.kbps) kbps \($0.codec)" }) }
    }

    // MARK: - Party application (no echo: applyingPartyState suppresses delegate)

    public func applyPartyTrack(_ track: Track, queue newQueue: [Track], queueIndex: Int, positionMs: Int, isPlaying: Bool, delayMs: Int64) {
        applyingPartyState = true; defer { applyingPartyState = false }
        queue = newQueue
        if let idx = newQueue.firstIndex(of: track) { currentIndex = idx }
        else if newQueue.indices.contains(queueIndex) { currentIndex = queueIndex; queue.insert(track, at: queueIndex); currentIndex = queueIndex }
        else { queue.append(track); currentIndex = queue.count - 1 }
        // If this device already has the same track loaded, a plain seek/play
        // avoids re-resolving the stream on every heartbeat.
        let alreadyLoaded = currentTrack?.id == track.id && player.currentItem != nil
        let start = Double(positionMs) / 1000.0
        if alreadyLoaded {
            applyPartyPlayState(isPlaying: isPlaying, positionMs: positionMs, delayMs: delayMs)
        } else {
            Task {
                if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
                self.applyingPartyState = true; defer { self.applyingPartyState = false }
                await self.loadCurrentTrack(startPosition: start, autoplay: isPlaying)
            }
        }
    }
    public func applyPartyPlayState(isPlaying: Bool, positionMs: Int, delayMs: Int64) {
        applyingPartyState = true; defer { applyingPartyState = false }
        let start = Double(positionMs) / 1000.0
        if delayMs > 0, isPlaying, !self.isPlaying {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                self.applyingPartyState = true; defer { self.applyingPartyState = false }
                self.seek(to: start); self.play()
            }
            return
        }
        if abs(position - start) > 1.5 { seek(to: start) }
        if isPlaying, !self.isPlaying { play() }
        else if !isPlaying, self.isPlaying { pause() }
    }
    public func applyPartySeek(positionMs: Int, delayMs: Int64) {
        if delayMs > 0 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                self.applyingPartyState = true; defer { self.applyingPartyState = false }
                self.seek(to: Double(positionMs) / 1000.0)
            }
        } else {
            applyingPartyState = true; defer { applyingPartyState = false }
            seek(to: Double(positionMs) / 1000.0)
        }
    }
    public func applyPartyQueue(_ newQueue: [Track], index: Int) {
        applyingPartyState = true; defer { applyingPartyState = false }
        // Preserve the currently playing track object if it is in the new queue.
        let wasPlaying = isPlaying
        queue = newQueue; currentIndex = newQueue.indices.contains(index) ? index : currentIndex
        if !wasPlaying { player.pause() }
    }
    public func detachParty() { partyDelegate = nil }
}
