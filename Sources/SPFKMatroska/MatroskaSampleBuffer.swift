// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreMedia
import Foundation

/// Errors thrown while packaging demuxed frames for Core Media.
public enum MatroskaSampleBufferError: Error, Equatable, Sendable {
    /// The track states no `CodecPrivate`, which for H.264 and HEVC is the codec configuration a
    /// decoder cannot start without.
    case missingCodecPrivate(codecID: String)

    /// A codec with no Core Media equivalent, or one whose configuration this package does not know
    /// how to describe.
    case unsupportedCodec(String)

    /// The track is not video, or states no pixel dimensions.
    case missingVideoParameters

    /// The track is not audio, or states no sample rate.
    case missingAudioParameters

    /// Core Media refused the description or the buffer. Carries its `OSStatus`.
    case coreMediaFailure(OSStatus)
}

// MARK: - Format description

public extension MatroskaTrack {
    /// The sample-description atom key Core Media expects a codec's configuration under, matching
    /// the ISO-BMFF box name for the same data.
    private var configurationAtomKey: String? {
        switch codecID {
        case "V_MPEG4/ISO/AVC": "avcC"
        case "V_MPEGH/ISO/HEVC": "hvcC"
        case "V_AV1": "av1C"
        case "V_VP9": "vpcC"
        default: nil
        }
    }

    /// Builds the `CMVideoFormatDescription` a decoder needs to make sense of this track's frames.
    ///
    /// `CodecPrivate` goes in verbatim as a sample-description extension atom — Matroska stores
    /// exactly the ISO-BMFF configuration box (`avcC` for H.264), which is why no conversion is
    /// needed and why the demuxer hands the blob back untouched.
    ///
    /// - Throws: ``MatroskaSampleBufferError``.
    func makeFormatDescription() throws -> CMVideoFormatDescription {
        guard case let .video(parameters) = kind,
              parameters.pixelWidth > 0, parameters.pixelHeight > 0
        else {
            throw MatroskaSampleBufferError.missingVideoParameters
        }

        guard let codecFourCC, let codecType = MatroskaTrack.codecType(for: codecFourCC) else {
            throw MatroskaSampleBufferError.unsupportedCodec(codecID)
        }

        var extensions: [CFString: Any] = [:]

        if let configurationAtomKey, let codecPrivate, codecPrivate.isEmpty == false {
            extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
                [configurationAtomKey: codecPrivate] as CFDictionary

        } else if MatroskaTrack.requiresCodecPrivate.contains(codecID) {
            // H.264 and HEVC keep their parameter sets out of band, so a decoder has nothing to
            // start from without this. VP9 and AV1 carry theirs in the bitstream and legitimately
            // ship no CodecPrivate at all -- refusing those would reject every WebM file.
            throw MatroskaSampleBufferError.missingCodecPrivate(codecID: codecID)
        }

        var formatDescription: CMVideoFormatDescription?

        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(parameters.pixelWidth),
            height: Int32(parameters.pixelHeight),
            extensions: extensions.isEmpty ? nil : extensions as CFDictionary,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDescription else {
            throw MatroskaSampleBufferError.coreMediaFailure(status)
        }

        return formatDescription
    }

    /// Builds the `CMAudioFormatDescription` a renderer needs to decode this track's packets.
    ///
    /// `CodecPrivate` becomes the magic cookie for the codecs that need one — for AAC that blob
    /// *is* the AudioSpecificConfig, the same "stored verbatim" property `avcC` has on the video
    /// side. See ``MatroskaAudioCodec/usesCodecPrivateAsMagicCookie``.
    ///
    /// - Throws: ``MatroskaSampleBufferError``.
    func makeAudioFormatDescription() throws -> CMAudioFormatDescription {
        guard case let .audio(parameters) = kind, parameters.sampleRate > 0 else {
            throw MatroskaSampleBufferError.missingAudioParameters
        }

        guard let codec = MatroskaAudioCodec(rawValue: codecID) else {
            throw MatroskaSampleBufferError.unsupportedCodec(codecID)
        }

        var description = AudioStreamBasicDescription(
            mSampleRate: parameters.sampleRate,
            mFormatID: codec.formatID,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: codec.framesPerPacket,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(parameters.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )

        let cookie = codec.usesCodecPrivateAsMagicCookie ? codecPrivate : nil

        var formatDescription: CMAudioFormatDescription?

        let status = (cookie.flatMap { $0.isEmpty ? nil : $0 } ?? Data()).withUnsafeBytes { bytes in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &description,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: bytes.count,
                magicCookie: bytes.count > 0 ? bytes.baseAddress : nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
        }

        guard status == noErr, let formatDescription else {
            throw MatroskaSampleBufferError.coreMediaFailure(status)
        }

        return formatDescription
    }

    /// Codecs whose parameter sets live outside the bitstream, so a decoder cannot start without
    /// the configuration blob.
    private static let requiresCodecPrivate: Set<String> = ["V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC"]

    /// Read from the `kCMVideoCodecType_*` constants rather than transcribed, same as
    /// ``codecFourCC``.
    private static func codecType(for fourCC: String) -> CMVideoCodecType? {
        switch fourCC {
        case "avc1": kCMVideoCodecType_H264
        case "hvc1": kCMVideoCodecType_HEVC
        case "av01": kCMVideoCodecType_AV1
        case "vp09": kCMVideoCodecType_VP9
        case "mp4v": kCMVideoCodecType_MPEG4Video
        default: nil
        }
    }
}

// MARK: - Sample buffers

public extension MatroskaFrame {
    /// Wraps this frame as a `CMSampleBuffer` ready to enqueue for decode or display.
    ///
    /// **The decode timestamp is deliberately invalid.** Matroska stores presentation time and no
    /// container-level DTS, and frames come out of the demuxer in stored order — which *is* decode
    /// order. Inventing a DTS would either duplicate that ordering or contradict it.
    ///
    /// Takes a plain `CMFormatDescription` rather than the video-specific spelling because audio
    /// frames go through the same packaging — one Matroska frame is one packet either way.
    ///
    /// - Throws: ``MatroskaSampleBufferError``.
    func makeSampleBuffer(formatDescription: CMFormatDescription) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?

        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw MatroskaSampleBufferError.coreMediaFailure(status)
        }

        status = data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }

            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }

        guard status == kCMBlockBufferNoErr else {
            throw MatroskaSampleBufferError.coreMediaFailure(status)
        }

        // Nanosecond timescale: Matroska's own timestamps are nanoseconds once scaled, so this
        // round-trips them exactly rather than quantizing to a frame rate the file never stated.
        var timing = CMSampleTimingInfo(
            duration: duration.map { CMTime(seconds: $0, preferredTimescale: 1_000_000_000) } ?? .invalid,
            presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )

        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else {
            throw MatroskaSampleBufferError.coreMediaFailure(status)
        }

        markSyncAttachment(on: sampleBuffer)

        return sampleBuffer
    }

    /// Marks a non-keyframe as "not a sync sample".
    ///
    /// Absence of the attachment means *sync*, so a display layer told nothing would treat every
    /// frame as a seek target and a decoder would try to start on a P-frame. Only the negative case
    /// needs stating.
    private func markSyncAttachment(on sampleBuffer: CMSampleBuffer) {
        guard isKeyframe == false,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0
        else {
            return
        }

        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)

        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
