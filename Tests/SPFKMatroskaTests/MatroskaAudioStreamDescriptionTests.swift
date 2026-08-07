// Copyright Ryan Francesconi. All Rights Reserved.

import CoreMedia
import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// The stream description is the whole of the FLAC and PCM work: Core Audio answers a wrong one by
/// consuming every packet, producing no audio, and reporting success, so these assertions are the
/// only place the difference is visible before playback.
@Suite(.tags(.file), .serialized)
struct MatroskaAudioStreamDescriptionTests {
    private func audioTrack(of url: URL) throws -> MatroskaTrack {
        let file = try MatroskaFile(url: url)

        return try #require(file.audioTrack)
    }

    // MARK: - FLAC

    @Test func flacPacketLengthComesFromTheFile() throws {
        let track = try audioTrack(of: TestBundleResources.shared.tabla_flac_mka)
        let streamInfo = try #require(track.flacStreamInfo)
        let description = try track.makeAudioStreamBasicDescription()

        // Zero was the defect: Core Audio cannot infer a FLAC packet length and builds a converter
        // that decodes silence when told nothing.
        #expect(description.mFramesPerPacket > 0)
        #expect(description.mFramesPerPacket == UInt32(streamInfo.maximumBlockSize))
    }

    /// `STREAMINFO` and the `TrackEntry` describe the same audio from different parts of the file,
    /// so they agreeing is what makes either believable.
    @Test func flacStreamInfoAgreesWithTheTrackEntry() throws {
        let track = try audioTrack(of: TestBundleResources.shared.tabla_flac_mka)
        let streamInfo = try #require(track.flacStreamInfo)

        guard case let .audio(parameters) = track.kind else {
            Issue.record("not an audio track")
            return
        }

        #expect(Double(streamInfo.sampleRate) == parameters.sampleRate)
        #expect(streamInfo.channelCount == parameters.channelCount)
        #expect(streamInfo.bitsPerSample == parameters.bitDepth)
    }

    @Test func flacCarriesItsSourceDepthFlag() throws {
        let track = try audioTrack(of: TestBundleResources.shared.tabla_flac_mka)
        let streamInfo = try #require(track.flacStreamInfo)
        let description = try track.makeAudioStreamBasicDescription()

        let expected: AudioFormatFlags = switch streamInfo.bitsPerSample {
        case 16: kAppleLosslessFormatFlag_16BitSourceData
        case 20: kAppleLosslessFormatFlag_20BitSourceData
        case 24: kAppleLosslessFormatFlag_24BitSourceData
        default: kAppleLosslessFormatFlag_32BitSourceData
        }

        #expect(description.mFormatID == kAudioFormatFLAC)
        #expect(description.mFormatFlags == expected)
    }

    @Test func flacWithoutCodecPrivateIsRefused() throws {
        let track = MatroskaTrack.stub(codecID: "A_FLAC", bitDepth: 24, codecPrivate: nil)

        #expect(throws: MatroskaSampleBufferError.missingCodecPrivate(codecID: "A_FLAC")) {
            try track.makeAudioStreamBasicDescription()
        }
    }

    /// FLAC admits depths Core Audio has no flag for, and there is no neighboring value to round to
    /// — a flag that disagrees with the stream decodes to silence.
    @Test func flacAtAnUnmappableDepthIsRefused() throws {
        let track = MatroskaTrack.stub(
            codecID: "A_FLAC",
            bitDepth: 12,
            codecPrivate: .flacStreamInfo(maximumBlockSize: 4096, sampleRate: 48000, channels: 2, bitsPerSample: 12)
        )

        #expect(throws: (any Error).self) {
            try track.makeAudioStreamBasicDescription()
        }

        #expect(track.isDecodable == false)
    }

    /// The timing grid a player puts packets on needs every packet to be the same length, which
    /// only `STREAMINFO` can say.
    @Test func flacOffersAPacketGridOnlyWhenItsBlockSizeIsFixed() throws {
        let track = try audioTrack(of: TestBundleResources.shared.tabla_flac_mka)
        let streamInfo = try #require(track.flacStreamInfo)

        #expect(streamInfo.hasFixedBlockSize)
        #expect(track.audioFramesPerPacket == UInt32(streamInfo.maximumBlockSize))

        let variable = MatroskaTrack.stub(
            codecID: "A_FLAC",
            bitDepth: 24,
            codecPrivate: .flacStreamInfo(
                minimumBlockSize: 1152,
                maximumBlockSize: 4096,
                sampleRate: 48000,
                channels: 2,
                bitsPerSample: 24
            )
        )

        #expect(variable.audioFramesPerPacket == nil)

        // Still decodable — a variable-block stream decodes fine, it just cannot be timed by grid.
        #expect(variable.isDecodable)
    }

    /// PCM blocks hold whatever the muxer chose, so there is no packet length to grid on.
    @Test func pcmOffersNoPacketGrid() throws {
        #expect(try audioTrack(of: TestBundleResources.shared.tabla_pcm_mka).audioFramesPerPacket == nil)
    }

    // MARK: - STREAMINFO parsing

    @Test func streamInfoReadsAMarkerPrefixedBlock() throws {
        let codecPrivate = Data.flacStreamInfo(
            maximumBlockSize: 4608,
            sampleRate: 44100,
            channels: 1,
            bitsPerSample: 16
        )

        let streamInfo = try #require(MatroskaFLACStreamInfo(codecPrivate: codecPrivate))

        #expect(streamInfo.maximumBlockSize == 4608)
        #expect(streamInfo.sampleRate == 44100)
        #expect(streamInfo.channelCount == 1)
        #expect(streamInfo.bitsPerSample == 16)
    }

    /// The marker and block header are what a muxer is most likely to differ on; the 34-byte body
    /// is unambiguous either way.
    @Test func streamInfoReadsABareBody() throws {
        let full = Data.flacStreamInfo(
            maximumBlockSize: 1024,
            sampleRate: 96000,
            channels: 6,
            bitsPerSample: 24
        )

        let streamInfo = try #require(MatroskaFLACStreamInfo(codecPrivate: Data(full.dropFirst(8))))

        #expect(streamInfo.maximumBlockSize == 1024)
        #expect(streamInfo.sampleRate == 96000)
        #expect(streamInfo.channelCount == 6)
        #expect(streamInfo.bitsPerSample == 24)
    }

    @Test func streamInfoRejectsTruncatedData() {
        #expect(MatroskaFLACStreamInfo(codecPrivate: Data([0x66, 0x4C, 0x61, 0x43, 0x80, 0, 0, 0x22])) == nil)
        #expect(MatroskaFLACStreamInfo(codecPrivate: Data()) == nil)
    }

    @Test func streamInfoReportsAVariableBlockSize() throws {
        let fixed = Data.flacStreamInfo(
            maximumBlockSize: 4096,
            sampleRate: 48000,
            channels: 2,
            bitsPerSample: 16
        )

        let variable = Data.flacStreamInfo(
            minimumBlockSize: 256,
            maximumBlockSize: 4096,
            sampleRate: 48000,
            channels: 2,
            bitsPerSample: 16
        )

        #expect(try #require(MatroskaFLACStreamInfo(codecPrivate: fixed)).hasFixedBlockSize)
        #expect(try #require(MatroskaFLACStreamInfo(codecPrivate: variable)).hasFixedBlockSize == false)
    }

    // MARK: - PCM

    @Test func pcmDescribesItsFrameSize() throws {
        let track = try audioTrack(of: TestBundleResources.shared.tabla_pcm_mka)
        let description = try track.makeAudioStreamBasicDescription()

        guard case let .audio(parameters) = track.kind, let bitDepth = parameters.bitDepth else {
            Issue.record("not a PCM audio track")
            return
        }

        let bytesPerFrame = UInt32(bitDepth / 8 * parameters.channelCount)

        #expect(description.mFormatID == kAudioFormatLinearPCM)
        #expect(description.mFramesPerPacket == 1)
        #expect(description.mBytesPerFrame == bytesPerFrame)
        #expect(description.mBytesPerPacket == bytesPerFrame)
        #expect(description.mBitsPerChannel == UInt32(bitDepth))
        #expect(description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
        #expect(description.mFormatFlags & kAudioFormatFlagIsBigEndian == 0)
    }

    /// Matroska inherits WAV's rule that 8-bit integer samples are unsigned and wider ones signed,
    /// under one CodecID — so signedness cannot be read off the codec table.
    @Test func eightBitPCMIsUnsigned() throws {
        let wide = try MatroskaTrack.stub(codecID: "A_PCM/INT/LIT", bitDepth: 16)
            .makeAudioStreamBasicDescription()

        let narrow = try MatroskaTrack.stub(codecID: "A_PCM/INT/LIT", bitDepth: 8)
            .makeAudioStreamBasicDescription()

        #expect(wide.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
        #expect(narrow.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0)
    }

    @Test func bigEndianPCMIsFlagged() throws {
        let description = try MatroskaTrack.stub(codecID: "A_PCM/INT/BIG", bitDepth: 16)
            .makeAudioStreamBasicDescription()

        #expect(description.mFormatFlags & kAudioFormatFlagIsBigEndian != 0)
        #expect(description.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0)
    }

    @Test func floatPCMIsFlagged() throws {
        let description = try MatroskaTrack.stub(codecID: "A_PCM/FLOAT/IEEE", bitDepth: 32)
            .makeAudioStreamBasicDescription()

        #expect(description.mFormatFlags & kAudioFormatFlagIsFloat != 0)
        #expect(description.mFormatFlags & kAudioFormatFlagIsSignedInteger == 0)
    }

    @Test func pcmWithoutABitDepthIsRefused() throws {
        let track = MatroskaTrack.stub(codecID: "A_PCM/INT/LIT", bitDepth: nil)

        #expect(throws: (any Error).self) {
            try track.makeAudioStreamBasicDescription()
        }

        #expect(track.isDecodable == false)
    }

    @Test func pcmAtANonByteWidthIsRefused() throws {
        #expect(throws: (any Error).self) {
            try MatroskaTrack.stub(codecID: "A_PCM/INT/LIT", bitDepth: 20).makeAudioStreamBasicDescription()
        }

        #expect(throws: (any Error).self) {
            try MatroskaTrack.stub(codecID: "A_PCM/FLOAT/IEEE", bitDepth: 16).makeAudioStreamBasicDescription()
        }
    }

    // MARK: - Decodability

    @Test func losslessTracksReportAsDecodable() throws {
        #expect(try audioTrack(of: TestBundleResources.shared.tabla_flac_mka).isDecodable)
        #expect(try audioTrack(of: TestBundleResources.shared.tabla_pcm_mka).isDecodable)
    }

    @Test func aCodecWithNoTableEntryIsNotDecodable() {
        #expect(MatroskaTrack.stub(codecID: "A_DTS", bitDepth: 24).isDecodable == false)
    }
}

// MARK: - Fixtures

private extension MatroskaTrack {
    /// A track with only the fields the stream description reads, for configurations no bundled
    /// file carries.
    static func stub(codecID: String, bitDepth: Int?, codecPrivate: Data? = nil) -> MatroskaTrack {
        MatroskaTrack(
            number: 1,
            kind: .audio(AudioParameters(sampleRate: 48000, channelCount: 2, bitDepth: bitDepth)),
            codecID: codecID,
            codecName: nil,
            name: nil,
            language: nil,
            codecPrivate: codecPrivate,
            defaultFrameDurationNanoseconds: nil
        )
    }
}

private extension Data {
    /// A FLAC header stream carrying one `STREAMINFO` block with the given fields.
    static func flacStreamInfo(
        minimumBlockSize: Int? = nil,
        maximumBlockSize: Int,
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int
    ) -> Data {
        var bytes: [UInt8] = [0x66, 0x4C, 0x61, 0x43, 0x80, 0x00, 0x00, 0x22]

        let minimum = minimumBlockSize ?? maximumBlockSize

        bytes += [UInt8(minimum >> 8), UInt8(minimum & 0xFF)]
        bytes += [UInt8(maximumBlockSize >> 8), UInt8(maximumBlockSize & 0xFF)]
        bytes += [0, 0, 0, 0, 0, 0]

        // 20 bits of sample rate, 3 of channels less one, 5 of depth less one, then 36 of total
        // samples — 64 bits from byte 10, of which only the first 28 are set here.
        let packed = UInt64(sampleRate) << 44
            | UInt64(channels - 1) << 41
            | UInt64(bitsPerSample - 1) << 36

        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((packed >> UInt64(shift)) & 0xFF))
        }

        bytes += [UInt8](repeating: 0, count: 16)

        return Data(bytes)
    }
}
