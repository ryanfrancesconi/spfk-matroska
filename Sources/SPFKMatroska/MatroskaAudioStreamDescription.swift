// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreMedia
import Foundation

public extension MatroskaTrack {
    /// The `AudioStreamBasicDescription` Core Audio needs to decode this track's packets.
    ///
    /// The single description of a Matroska audio track: every consumer builds its format from this
    /// one, because a second hand-rolled copy is how a field goes missing in one path and not the
    /// other.
    ///
    /// **A wrong field here builds an `AVAudioConverter` that decodes nothing and reports no error**,
    /// which is why FLAC's packet length and source depth are read from the file rather than
    /// assumed, and why an unmappable configuration throws.
    ///
    /// - Throws: ``MatroskaSampleBufferError``.
    func makeAudioStreamBasicDescription() throws -> AudioStreamBasicDescription {
        guard case let .audio(parameters) = kind, parameters.sampleRate > 0, parameters.channelCount > 0 else {
            throw MatroskaSampleBufferError.missingAudioParameters
        }

        guard let codec = MatroskaAudioCodec(rawValue: codecID) else {
            throw MatroskaSampleBufferError.unsupportedCodec(codecID)
        }

        if let sampleFormat = codec.pcmSampleFormat {
            return try pcmStreamDescription(parameters: parameters, sampleFormat: sampleFormat)
        }

        if codec == .flac {
            return try flacStreamDescription(parameters: parameters)
        }

        return AudioStreamBasicDescription(
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
    }

    /// Frames in every packet, or `nil` for a track whose packets are not all the same length.
    ///
    /// What a fixed timing grid can be built on. FLAC answers only when `STREAMINFO` states one
    /// block size for the whole stream; a variable-block encoder would put every packet after the
    /// first in the wrong place.
    var audioFramesPerPacket: UInt32? {
        guard let codec = MatroskaAudioCodec(rawValue: codecID) else { return nil }

        if codec.framesPerPacket > 0 {
            return codec.framesPerPacket
        }

        guard codec == .flac, let streamInfo = flacStreamInfo, streamInfo.hasFixedBlockSize else {
            return nil
        }

        return UInt32(streamInfo.maximumBlockSize)
    }

    /// The FLAC stream's `STREAMINFO`, or `nil` when the track is not FLAC or states no usable
    /// `CodecPrivate`.
    var flacStreamInfo: MatroskaFLACStreamInfo? {
        guard codecID == MatroskaAudioCodec.flac.rawValue, let codecPrivate else { return nil }

        return MatroskaFLACStreamInfo(codecPrivate: codecPrivate)
    }

    // MARK: - Per-codec

    /// Core Audio describes FLAC by its maximum block size and a source-depth flag, both of which
    /// `STREAMINFO` states and neither of which the CodecID implies.
    private func flacStreamDescription(
        parameters: AudioParameters
    ) throws -> AudioStreamBasicDescription {
        guard let codecPrivate, codecPrivate.isEmpty == false else {
            throw MatroskaSampleBufferError.missingCodecPrivate(codecID: codecID)
        }

        guard let streamInfo = MatroskaFLACStreamInfo(codecPrivate: codecPrivate) else {
            throw MatroskaSampleBufferError.unsupportedAudioConfiguration(
                codecID: codecID,
                detail: "CodecPrivate is not a readable STREAMINFO block"
            )
        }

        // FLAC admits 8 and 12 bit, which Core Audio's four source-depth flags cannot express. There
        // is no neighboring value to round to -- a flag that disagrees with the stream decodes to
        // silence -- so this refuses instead.
        let sourceDepthFlag: AudioFormatFlags = switch streamInfo.bitsPerSample {
        case 16: kAppleLosslessFormatFlag_16BitSourceData
        case 20: kAppleLosslessFormatFlag_20BitSourceData
        case 24: kAppleLosslessFormatFlag_24BitSourceData
        case 32: kAppleLosslessFormatFlag_32BitSourceData
        default: 0
        }

        guard sourceDepthFlag != 0 else {
            throw MatroskaSampleBufferError.unsupportedAudioConfiguration(
                codecID: codecID,
                detail: "\(streamInfo.bitsPerSample)-bit FLAC has no Core Audio source-depth flag"
            )
        }

        guard streamInfo.maximumBlockSize > 0 else {
            throw MatroskaSampleBufferError.unsupportedAudioConfiguration(
                codecID: codecID,
                detail: "STREAMINFO states no maximum block size"
            )
        }

        return AudioStreamBasicDescription(
            mSampleRate: parameters.sampleRate,
            mFormatID: kAudioFormatFLAC,
            mFormatFlags: sourceDepthFlag,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(streamInfo.maximumBlockSize),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(parameters.channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }

    /// Interleaved, packed, one frame per packet — a Matroska PCM block is raw samples with no
    /// framing of any kind.
    private func pcmStreamDescription(
        parameters: AudioParameters,
        sampleFormat: MatroskaPCMSampleFormat
    ) throws -> AudioStreamBasicDescription {
        guard let bitDepth = parameters.bitDepth else {
            throw MatroskaSampleBufferError.unsupportedAudioConfiguration(
                codecID: codecID,
                detail: "PCM track states no BitDepth"
            )
        }

        var flags: AudioFormatFlags = kAudioFormatFlagIsPacked

        switch sampleFormat {
        case .float:
            guard bitDepth == 32 || bitDepth == 64 else {
                throw MatroskaSampleBufferError.unsupportedAudioConfiguration(
                    codecID: codecID,
                    detail: "\(bitDepth)-bit float PCM is not an IEEE 754 width"
                )
            }

            flags |= kAudioFormatFlagIsFloat

        case let .integer(isBigEndian):
            guard bitDepth == 8 || bitDepth == 16 || bitDepth == 24 || bitDepth == 32 else {
                throw MatroskaSampleBufferError.unsupportedAudioConfiguration(
                    codecID: codecID,
                    detail: "\(bitDepth)-bit integer PCM is not a whole number of bytes per sample"
                )
            }

            if bitDepth > 8 {
                flags |= kAudioFormatFlagIsSignedInteger
            }

            if isBigEndian {
                flags |= kAudioFormatFlagIsBigEndian
            }
        }

        let bytesPerFrame = UInt32(bitDepth / 8 * parameters.channelCount)

        return AudioStreamBasicDescription(
            mSampleRate: parameters.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: flags,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(parameters.channelCount),
            mBitsPerChannel: UInt32(bitDepth),
            mReserved: 0
        )
    }
}

// MARK: - STREAMINFO

/// The fields of a FLAC `STREAMINFO` block a decoder has to be told about.
public struct MatroskaFLACStreamInfo: Hashable, Sendable {
    /// Frames in the longest packet. Core Audio wants this as the packet length, and a smaller value
    /// decodes to silence.
    public let maximumBlockSize: Int

    public let minimumBlockSize: Int
    public let sampleRate: Int
    public let channelCount: Int

    /// 4 to 32 in the FLAC specification, so not every value maps onto a Core Audio source depth.
    public let bitsPerSample: Int

    /// Whether every packet is the same length, which is what makes a fixed packet grid valid.
    public var hasFixedBlockSize: Bool { minimumBlockSize == maximumBlockSize }

    /// Reads a Matroska FLAC track's `CodecPrivate`, which holds the file's header stream: the
    /// `fLaC` marker, then metadata blocks of which `STREAMINFO` is always the first.
    ///
    /// Accepts a bare `STREAMINFO` payload too — the marker and block header are what a muxer is
    /// most likely to differ on, and the 34-byte body is unambiguous either way.
    public init?(codecPrivate: Data) {
        let bytes = [UInt8](codecPrivate)
        var offset = 0

        if bytes.count >= 4, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
            // "fLaC", then a 4-byte metadata block header whose low 7 bits of the first byte are the
            // block type. STREAMINFO is type 0 and required to come first.
            guard bytes.count >= 8, bytes[4] & 0x7F == 0 else { return nil }

            offset = 8
        }

        guard bytes.count >= offset + 34 else { return nil }

        let body = Array(bytes[offset ..< offset + 34])

        minimumBlockSize = Int(body[0]) << 8 | Int(body[1])
        maximumBlockSize = Int(body[2]) << 8 | Int(body[3])

        // A packed bit field from byte 10: 20 bits of sample rate, 3 of channel count less one,
        // 5 of bit depth less one.
        let packed = UInt64(body[10]) << 28
            | UInt64(body[11]) << 20
            | UInt64(body[12]) << 12
            | UInt64(body[13]) << 4
            | UInt64(body[14]) >> 4

        sampleRate = Int(packed >> 16)
        channelCount = Int((packed >> 13) & 0b111) + 1
        bitsPerSample = Int((packed >> 8) & 0b1_1111) + 1

        guard sampleRate > 0, maximumBlockSize > 0 else { return nil }
    }
}
