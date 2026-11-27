import Foundation
import AVFoundation

/// The composition's sound: every AudioClip laid on its own track of an AVMutableComposition, with volume ramps
/// for fades, ready to be read as PCM through AVAssetReaderAudioMixOutput.
public struct MediaAudioMix: @unchecked Sendable {
    public let composition: AVMutableComposition
    public let audioMix: AVMutableAudioMix
    public let tracks: [AVMutableCompositionTrack]
    /// Length of the mix in seconds (the composition's duration).
    public let duration: Double

    /// PCM settings used when reading the mix.
    public static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// nil when no clip has usable audio (missing assets and files without an audio track are skipped).
    public static func build(config: CompositionConfig, assets: [String: URL]) async -> MediaAudioMix? {
        await build(config: config, assets: assets, warn: nil)
    }

    /// Like `build(config:assets:)`; `warn` is told about every clip that had to be left out and why.
    public static func build(config: CompositionConfig, assets: [String: URL], warn: (@Sendable (String) -> Void)?) async -> MediaAudioMix? {
        guard let clips = config.audio, !clips.isEmpty else { return nil }
        let fps = Double(max(1, config.fps))
        let total = config.duration
        let timescale: CMTimeScale = 48_000
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: timescale) }

        let comp = AVMutableComposition()
        var params: [AVMutableAudioMixInputParameters] = []
        var compTracks: [AVMutableCompositionTrack] = []
        var assetCache: [String: (AVURLAsset, AVAssetTrack, Double)] = [:]

        for clip in clips {
            guard let url = assets[clip.src] else { warn?(AssetCheck.message(id: clip.src, kind: .audio, url: nil)); continue }
            if assetCache[clip.src] == nil {
                let asset = AVURLAsset(url: url)
                guard let at = try? await asset.loadTracks(withMediaType: .audio).first,
                      let dur = try? await asset.load(.duration).seconds, dur.isFinite, dur > 0 else {
                    warn?(await AssetCheck.audioProblem(id: clip.src, url: url, asset: asset))
                    continue
                }
                assetCache[clip.src] = (asset, at, dur)
            }
            guard let (_, srcTrack, srcDur) = assetCache[clip.src] else { continue }

            let start = Double(max(0, clip.startFrame ?? 0)) / fps
            let offset = max(0, clip.offset ?? 0)
            var dur = min(srcDur - offset, total - start)
            if let f = clip.durationInFrames { dur = min(dur, Double(f) / fps) }
            guard dur > 0.0005,
                  let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            do { try ct.insertTimeRange(CMTimeRange(start: cm(offset), duration: cm(dur)), of: srcTrack, at: cm(start)) }
            catch { comp.removeTrack(ct); continue }

            let vol = Float(min(1, max(0, clip.volume ?? 1)))
            var fi = max(0, clip.fadeIn ?? 0), fo = max(0, clip.fadeOut ?? 0)
            if fi + fo > dur { let k = dur / (fi + fo); fi *= k; fo *= k }
            let p = AVMutableAudioMixInputParameters(track: ct)
            if fi > 0 {
                p.setVolume(0, at: .zero)
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol, timeRange: CMTimeRange(start: cm(start), duration: cm(fi)))
            } else {
                p.setVolume(vol, at: cm(start))
            }
            if fo > 0 {
                p.setVolume(vol, at: cm(start + fi))
                p.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0, timeRange: CMTimeRange(start: cm(start + dur - fo), duration: cm(fo)))
            }
            params.append(p)
            compTracks.append(ct)
        }
        guard !compTracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return MediaAudioMix(composition: comp, audioMix: mix, tracks: compTracks, duration: total)
    }

    /// A reader over the mixed sound, limited to the composition length, plus its PCM output (not yet started).
    public func makeReader() throws -> (AVAssetReader, AVAssetReaderAudioMixOutput) {
        let reader = try AVAssetReader(asset: composition)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: Self.pcmSettings)
        out.audioMix = audioMix
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { throw SprocketError(.export, "cannot read the audio mix") }
        reader.add(out)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 48_000))
        return (reader, out)
    }
}
