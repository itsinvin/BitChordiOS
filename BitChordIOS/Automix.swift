import Foundation
import AVFoundation

// MARK: - Automix (port of shared/playback/smart/*, Beta)
// Original: ONNX beat tracking + vocal separation on Android. On iOS there
// is no ONNX runtime bundled, so BPM comes from a real onset detector over
// decoded audio (AVAssetReader) instead of a neural model — the planner
// logic (4-bar overlap, tempo match, gain ride) is the original's.

public struct TransitionPlan: Equatable {
    public var overlapSeconds: Double
    public var incomingRate: Double
    public var beatMatched: Bool
    public var outgoingBPM: Double
    public var incomingBPM: Double
}

public enum Automix {
    public static var bpmCache: [String: Double] = [:]

    /// Plan a transition. Four bars = 16 beats at the average tempo, capped
    /// at the last 30 s of the outgoing track (original's Automix window).
    /// Tempos outside 40–220 BPM, or with no trusted BPM, fall back to a
    /// plain crossfade at the user's crossfade seconds.
    public static func plan(outgoingBPM: Double?, incomingBPM: Double?, crossfadeSeconds: Double) -> TransitionPlan {
        guard let out = outgoingBPM, let inn = incomingBPM,
              (40...220).contains(out), (40...220).contains(inn) else {
            return TransitionPlan(overlapSeconds: crossfadeSeconds, incomingRate: 1.0, beatMatched: false, outgoingBPM: outgoingBPM ?? 0, incomingBPM: incomingBPM ?? 0)
        }
        let avgBPM = (out + inn) / 2
        let fourBars = 16 * 60 / avgBPM
        let overlap = min(30, max(4, fourBars))
        let rate = inn > 0 ? out / inn : 1.0
        // Tempo-stretching a voice by more than ~8% sounds wrong; beyond
        // that the original also drops to a plain crossfade.
        guard (0.92...1.08).contains(rate) else {
            return TransitionPlan(overlapSeconds: crossfadeSeconds, incomingRate: 1.0, beatMatched: false, outgoingBPM: out, incomingBPM: inn)
        }
        return TransitionPlan(overlapSeconds: overlap, incomingRate: rate, beatMatched: true, outgoingBPM: out, incomingBPM: inn)
    }

    /// Gain ride for the overlap, t = 0..1 through the transition:
    /// outgoing fades out on a curve, incoming fades in, with a slight
    /// mid-transition dip (the DJ-filter feel) instead of a linear cross.
    public static func gains(at t: Double) -> (outgoing: Double, incoming: Double) {
        let clamped = max(0, min(1, t))
        let dip = 1 - 0.15 * sin(clamped * Double.pi)
        return ((1 - clamped) * dip, clamped * dip)
    }

    /// Estimate BPM from a local audio file: decode to mono PCM, take the
    /// energy envelope, find onset peaks, and take the median inter-onset
    /// interval that lands in 40–220 BPM. Returns nil for streamed tracks
    /// (no local file to analyse) and for files with no clear pulse.
    public static func estimateBPM(for url: URL) async -> Double? {
        if let cached = bpmCache[url.lastPathComponent] { return cached }
        let asset = AVAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        reader.add(output); reader.startReading()
        var energies: [Double] = []
        while let sample = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            var length = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
            guard let ptr, length > 0 else { continue }
            let samples = ptr.withMemoryRebound(to: Int16.self, capacity: length / 2) { Array(UnsafeBufferPointer(start: $0, count: length / 2)) }
            // One energy value per ~50 ms window.
            let window = 2205
            var i = 0
            while i + window <= samples.count {
                var sum = 0.0
                for s in samples[i..<(i + window)] { let v = Double(s) / 32768; sum += v * v }
                energies.append(sqrt(sum / Double(window)))
                i += window
            }
        }
        reader.cancelReading()
        guard energies.count > 40 else { return nil }
        let mean = energies.reduce(0, +) / Double(energies.count)
        var onsets: [Double] = []
        var lastOnset = -10.0
        for (i, e) in energies.enumerated() {
            let t = Double(i) * 0.05
            if e > mean * 1.6, t - lastOnset > 0.25 { onsets.append(t); lastOnset = t }
        }
        guard onsets.count > 8 else { return nil }
        var intervals: [Double] = []
        for i in 1..<onsets.count { intervals.append(onsets[i] - onsets[i - 1]) }
        intervals.sort()
        let median = intervals[intervals.count / 2]
        guard median > 0 else { return nil }
        let bpm = 60 / median
        guard (40...220).contains(bpm) else { return nil }
        bpmCache[url.lastPathComponent] = bpm
        return bpm
    }
}
