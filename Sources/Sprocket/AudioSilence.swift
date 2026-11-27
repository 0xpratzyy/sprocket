import Foundation
import AVFoundation
import CoreMedia

/// Silent PCM sample buffers, used to pad the audio stream out to the composition's length.
enum AudioSilence {
    static let sampleRate: Int64 = 48_000

    /// `startSample` and `frames` are in samples at 48 kHz. `format` is the description of the audio already written
    /// (so the padding matches it); nil means interleaved 32-bit float stereo, which is what the mix is read as.
    static func buffer(format: CMFormatDescription?, startSample: Int64, frames: Int) -> CMSampleBuffer? {
        var fd = format
        if fd == nil {
            var asbd = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
                                                   mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                   mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                   mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
            var made: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                 magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                 formatDescriptionOut: &made) == noErr else { return nil }
            fd = made
        }
        guard let fd, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee, asbd.mBytesPerFrame > 0 else { return nil }
        let bytes = frames * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        var sb: CMSampleBuffer?
        let rate = Int32(asbd.mSampleRate)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd, sampleCount: frames,
            presentationTimeStamp: CMTime(value: startSample, timescale: rate), packetDescriptions: nil,
            sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}
