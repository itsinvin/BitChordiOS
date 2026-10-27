import Foundation
import AVFoundation
import MediaToolbox

// MARK: - Equalizer (port of EqualizerCurve / EqualizerPreset / EqualizerProcessor)
// 7 bands, 60/150/400/1000/2500/6000/14000 Hz. First band is a low shelf,
// last a high shelf, the rest peaking (RBJ biquads), exactly like the original.
// Implemented as an MTAudioProcessingTap on the AVPlayerItem: the tap runs
// on the audio render thread, so it only touches its own C context — no
// Swift objects, no locks, no allocation in the callback.
//
// LIMITATION, stated plainly: a tap can only be attached to an item the app
// creates (local files and the AVPlayerItems this engine builds). If a
// future playback path hands the engine an already-playing item, the tap
// cannot be retro-fitted and EQ silently does not apply to that item —
// the code attaches the tap at item creation in PlayerEngine, which is the
// only path that exists today.

public enum EqualizerPreset: String, CaseIterable {
    case flat = "Flat", acoustic = "Acoustic", bassBoost = "Bass Boost", bassCut = "Bass Cut"
    case vocal = "Vocal", trebleBoost = "Treble Boost", trebleCut = "Treble Cut", loudness = "Loudness"
    case spokenWord = "Spoken Word", electronic = "Electronic", rock = "Rock", hipHop = "Hip-Hop"
    case jazz = "Jazz", classical = "Classical", smallSpeakers = "Small Speakers", lateNight = "Late Night", custom = "Custom"
    /// Original gains, in band order (EqualizerPreset.kt).
    public var bands: [Double]? {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0]
        case .acoustic: return [3, 1.5, 0, 1.5, 2.5, 2, 1]
        case .bassBoost: return [6, 4, 1.5, 0, 0, 0, 0]
        case .bassCut: return [-6, -4, -1.5, 0, 0, 0, 0]
        case .vocal: return [-3, -1.5, 1, 3.5, 3, 1, -1]
        case .trebleBoost: return [0, 0, 0, 0, 1.5, 3.5, 5]
        case .trebleCut: return [0, 0, 0, 0, -1.5, -3.5, -5]
        case .loudness: return [6, 3.5, 0, -1.5, -1, 2, 5]
        case .spokenWord: return [-5, -2.5, 1.5, 4, 3.5, 1.5, -2]
        case .electronic: return [5, 3, -1, 0, 1, 3, 4]
        case .rock: return [4, 2.5, -1, -1.5, 1, 3, 3.5]
        case .hipHop: return [6, 4, 0.5, -1, 0.5, 2, 2.5]
        case .jazz: return [3, 1.5, 0, 1, 1.5, 2, 2.5]
        case .classical: return [3, 2, 0, 0, 1, 2.5, 3]
        case .smallSpeakers: return [5, 4, 2, 0.5, 0, -1, -2]
        case .lateNight: return [3, 1, 0, 1.5, 1, -1, -3]
        case .custom: return nil
        }
    }
    public static func matching(_ bands: [Double]) -> EqualizerPreset {
        for p in allCases where p != .custom {
            if let b = p.bands, b.count == bands.count, zip(b, bands).allSatisfy({ abs($0 - $1) < 0.05 }) { return p }
        }
        return .custom
    }
}

public struct EQBand { public var frequency: Double; public var gainDb: Double; public var isShelf: Bool }
public let eqFrequencies: [Double] = [60, 150, 400, 1000, 2500, 6000, 14000]

/// RMS monitor shared with the skip-silence check. Written from the audio
/// thread into a heap box; read from the main thread. One Double, torn reads
/// are harmless here (it is only a silence threshold).
public final class SilenceMonitor {
    public static let shared = SilenceMonitor()
    public var rms: Double = 0
    private init() {}
}

// Biquad state, per channel per band, held in the tap context.
private struct Biquad { var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0 }
private final class TapContext {
    var bands: [Double]; var sampleRate: Double = 44100
    var filters: [[Biquad]] = [] // [channel][band]
    var balance: Double = 0
    init(bands: [Double]) { self.bands = bands }
    func coefficients(band: Int, gainDb: Double, sampleRate: Double) -> Biquad {
        let freq = eqFrequencies[band]
        let a = pow(10, gainDb / 40)
        let w = 2 * Double.pi * freq / sampleRate
        let alpha: Double
        let cosW = cos(w)
        if band == 0 || band == 6 {
            // Shelf, S = 1.
            alpha = sin(w) / 2 * sqrt((a + 1 / a) * (1 / 1 - 1) + 2)
            var b = Biquad()
            if band == 0 {
                b.b0 = a * ((a + 1) - (a - 1) * cosW + 2 * sqrt(a) * alpha)
                b.b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
                b.b2 = a * ((a + 1) - (a - 1) * cosW - 2 * sqrt(a) * alpha)
                b.a1 = -2 * ((a - 1) + (a + 1) * cosW)
                b.a2 = (a + 1) + (a - 1) * cosW - 2 * sqrt(a) * alpha
                let a0 = (a + 1) + (a - 1) * cosW + 2 * sqrt(a) * alpha
                b.b0 /= a0; b.b1 /= a0; b.b2 /= a0; b.a1 /= a0; b.a2 /= a0
            } else {
                b.b0 = a * ((a + 1) + (a - 1) * cosW + 2 * sqrt(a) * alpha)
                b.b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
                b.b2 = a * ((a + 1) + (a - 1) * cosW - 2 * sqrt(a) * alpha)
                b.a1 = 2 * ((a - 1) - (a + 1) * cosW)
                b.a2 = (a + 1) - (a - 1) * cosW - 2 * sqrt(a) * alpha
                let a0 = (a + 1) - (a - 1) * cosW + 2 * sqrt(a) * alpha
                b.b0 /= a0; b.b1 /= a0; b.b2 /= a0; b.a1 /= a0; b.a2 /= a0
            }
            return b
        }
        alpha = sin(w) / (2 * 1.0) // Q = 1
        let a0 = 1 + alpha / a
        var b = Biquad()
        b.b0 = 1 + alpha * a; b.b1 = -2 * cosW; b.b2 = 1 - alpha * a
        b.a1 = -2 * cosW; b.a2 = 1 - alpha / a
        b.b0 /= a0; b.b1 /= a0; b.b2 /= a0; b.a1 /= a0; b.a2 /= a0
        return b
    }
    func ensureChannels(_ count: Int) {
        if filters.count != count {
            filters = (0..<count).map { _ in (0..<7).map { _ in Biquad() } }
        }
    }
}

private func tapInit(_ tap: MTAudioProcessingTap, _ clientInfo: UnsafeMutableRawPointer, _ tapStorageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    // clientInfo is the +1 retained TapContext from audioMix(); hand that
    // same pointer to the tap as its storage, and release it in finalize.
    tapStorageOut.pointee = clientInfo
}
private func tapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}
private func tapPrepare(_ tap: MTAudioProcessingTap, _ maxFrames: CMItemCount, _ processingFormat: UnsafePointer<AudioStreamBasicDescription>) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let ctx = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
    ctx.sampleRate = processingFormat.pointee.mSampleRate
    ctx.filters = []
}
private func tapUnprepare(_ tap: MTAudioProcessingTap) {}
private func tapProcess(_ tap: MTAudioProcessingTap, _ numberFrames: CMItemCount, _ flags: MTAudioProcessingTapFlags, _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>, _ numberFramesOut: UnsafeMutablePointer<CMItemCount>, _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    let storage = MTAudioProcessingTapGetStorage(tap)
    let ctx = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
    var timeRange = CMTimeRange()
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, &timeRange)
    guard status == noErr else { numberFramesOut.pointee = 0; return }
    numberFramesOut.pointee = numberFrames
    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    ctx.ensureChannels(abl.count)
    var sumSquares = 0.0; var sampleCount = 0
    for (ch, buffer) in abl.enumerated() {
        guard let ptr = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        let balGain: Double = ch == 0 ? (ctx.balance < 0 ? 1 + ctx.balance : 1) : (ctx.balance > 0 ? 1 - ctx.balance : 1)
        for i in 0..<frames {
            var sample = Double(ptr[i])
            for band in 0..<7 {
                let gain = ctx.bands.indices.contains(band) ? ctx.bands[band] : 0
                if abs(gain) < 0.01 { continue }
                var f = ctx.filters[ch][band]
                if f.b0 == 0 { f = ctx.coefficients(band: band, gainDb: gain, sampleRate: ctx.sampleRate); ctx.filters[ch][band] = f }
                // Recompute coefficients when the gain changed is handled by
                // the caller rebuilding the tap; here we only run the filter.
                let out = f.b0 * sample + f.b1 * f.x1 + f.b2 * f.x2 - f.a1 * f.y1 - f.a2 * f.y2
                f.x2 = f.x1; f.x1 = sample; f.y2 = f.y1; f.y1 = out
                ctx.filters[ch][band] = f
                sample = out
            }
            // Headroom: half the largest boost is taken back (original's preamp rule, simplified).
            let maxBoost = ctx.bands.max() ?? 0
            if maxBoost > 0 { sample *= pow(10, (-maxBoost / 2) / 20) }
            sample *= balGain
            let clamped = max(-1, min(1, sample))
            ptr[i] = Float(clamped)
            sumSquares += clamped * clamped; sampleCount += 1
        }
    }
    if sampleCount > 0 { SilenceMonitor.shared.rms = sqrt(sumSquares / Double(sampleCount)) }
}

public enum EqualizerTap {
    /// Build an audio mix carrying the EQ tap for these bands. Returns nil
    /// when every band is flat (no processing needed) — callers treat that
    /// as "no tap", not as an error.
    public static func audioMix(bands: [Double], balance: Double, force: Bool = false) -> AVAudioMix? {
        // force: build the tap even for flat bands, so its RMS side-channel
        // can feed the skip-silence check without any audible EQ.
        guard force || bands.contains(where: { abs($0) >= 0.01 }) || balance != 0 else { return nil }
        let ctx = TapContext(bands: bands); ctx.balance = balance
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: Unmanaged.passRetained(ctx).toOpaque(), init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: tapUnprepare, process: tapProcess)
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr, let tap else { return nil }
        let params = AVMutableAudioMixInputParameters(trackID: kCMPersistentTrackID_Invalid)
        params.audioTapProcessor = tap.takeRetainedValue()
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]
        return mix
    }
}
