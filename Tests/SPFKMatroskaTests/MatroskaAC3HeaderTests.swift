// Copyright Ryan Francesconi. All Rights Reserved.

import CoreMedia
import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// The first seven bytes of real syncframes, one per layout, encoded by ffmpeg. Each expected
/// configuration is what ffprobe reported for the same file, and each tag is the layout Core Audio's
/// decoder output for it.
@Suite(.tags(.file))
struct MatroskaAC3HeaderTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let bytes: [UInt8]
        let channelCount: Int
        let tag: AudioChannelLayoutTag

        var testDescription: String { name }
    }

    static let ac3: [Case] = [
        Case(name: "AC-3 mono", bytes: [0x0B, 0x77, 0xFE, 0xBC, 0x1C, 0x40, 0x2F], channelCount: 1, tag: kAudioChannelLayoutTag_Mono),
        Case(name: "AC-3 stereo", bytes: [0x0B, 0x77, 0x9A, 0x0E, 0x1C, 0x40, 0x43], channelCount: 2, tag: kAudioChannelLayoutTag_Stereo),
        Case(name: "AC-3 2.1", bytes: [0x0B, 0x77, 0xAE, 0xF6, 0x1C, 0x40, 0x47], channelCount: 3, tag: kAudioChannelLayoutTag_DVD_4),
        Case(name: "AC-3 3.0", bytes: [0x0B, 0x77, 0x5D, 0x8E, 0x1C, 0x40, 0x6B], channelCount: 3, tag: kAudioChannelLayoutTag_AC3_3_0),
        Case(name: "AC-3 3.1", bytes: [0x0B, 0x77, 0xC0, 0xC4, 0x1C, 0x40, 0x6F], channelCount: 4, tag: kAudioChannelLayoutTag_AC3_3_0_1),
        Case(name: "AC-3 4.0", bytes: [0x0B, 0x77, 0xB9, 0x26, 0x1C, 0x40, 0xAA], channelCount: 4, tag: kAudioChannelLayoutTag_AC3_3_1),
        Case(name: "AC-3 quad", bytes: [0x0B, 0x77, 0x54, 0xF3, 0x1C, 0x40, 0xCB], channelCount: 4, tag: kAudioChannelLayoutTag_ITU_2_2),
        Case(name: "AC-3 4.1", bytes: [0x0B, 0x77, 0xA4, 0xDA, 0x1C, 0x40, 0xAB], channelCount: 5, tag: kAudioChannelLayoutTag_AC3_3_1_1),
        Case(name: "AC-3 5.0", bytes: [0x0B, 0x77, 0x08, 0xCD, 0x1C, 0x40, 0xEA], channelCount: 5, tag: kAudioChannelLayoutTag_MPEG_5_0_C),
        Case(name: "AC-3 5.1", bytes: [0x0B, 0x77, 0x50, 0x90, 0x1C, 0x40, 0xEB], channelCount: 6, tag: kAudioChannelLayoutTag_MPEG_5_1_C),
    ]

    static let eac3: [Case] = [
        Case(name: "E-AC-3 mono", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x32, 0x87, 0xC0], channelCount: 1, tag: kAudioChannelLayoutTag_Mono),
        Case(name: "E-AC-3 stereo", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x34, 0x87, 0xC0], channelCount: 2, tag: kAudioChannelLayoutTag_Stereo),
        Case(name: "E-AC-3 2.1", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x35, 0x87, 0xC0], channelCount: 3, tag: kAudioChannelLayoutTag_DVD_4),
        Case(name: "E-AC-3 3.0", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x36, 0x87, 0xC0], channelCount: 3, tag: kAudioChannelLayoutTag_AC3_3_0),
        Case(name: "E-AC-3 3.1", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x37, 0x87, 0xC0], channelCount: 4, tag: kAudioChannelLayoutTag_AC3_3_0_1),
        Case(name: "E-AC-3 4.0", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x3A, 0x87, 0xC0], channelCount: 4, tag: kAudioChannelLayoutTag_AC3_3_1),
        Case(name: "E-AC-3 quad", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x3C, 0x87, 0xC0], channelCount: 4, tag: kAudioChannelLayoutTag_ITU_2_2),
        Case(name: "E-AC-3 4.1", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x3B, 0x87, 0xC0], channelCount: 5, tag: kAudioChannelLayoutTag_AC3_3_1_1),
        Case(name: "E-AC-3 5.0", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x3E, 0x87, 0xC0], channelCount: 5, tag: kAudioChannelLayoutTag_MPEG_5_0_C),
        Case(name: "E-AC-3 5.1", bytes: [0x0B, 0x77, 0x02, 0xFF, 0x3F, 0x87, 0xC0], channelCount: 6, tag: kAudioChannelLayoutTag_MPEG_5_1_C),
    ]

    @Test(arguments: ac3 + eac3)
    func headerStatesTheLayout(_ testCase: Case) throws {
        let header = try #require(MatroskaAC3Header(frame: Data(testCase.bytes)))

        #expect(header.channelCount == testCase.channelCount)
        #expect(header.channelLayoutTag == testCase.tag)
        #expect(header.framesPerPacket == 1536)

        let codecID = header.isEnhanced ? "A_EAC3" : "A_AC3"
        let track = MatroskaTrack.audioStub(codecID: codecID, channelCount: testCase.channelCount)
        #expect(track.audioChannelLayoutTag(firstPacket: Data(testCase.bytes)) == testCase.tag)
    }

    @Test func dualMonoIsNotGivenALayout() throws {
        let header = try #require(MatroskaAC3Header(frame: Data([0x0B, 0x77, 0x00, 0x00, 0x1C, 0x40, 0x00])))

        #expect(header.audioCodingMode == 0)
        #expect(header.channelCount == 2)
        #expect(header.channelLayoutTag == nil)
    }

    /// A 7.1 E-AC-3 stream's independent substream states 3/2 + LFE while the track states 8.
    @Test func aHeaderDisagreeingWithTheTrackIsNotBelieved() {
        let track = MatroskaTrack.audioStub(codecID: "A_EAC3", channelCount: 8)

        #expect(track.audioChannelLayoutTag(firstPacket: Data(Self.eac3[9].bytes)) == nil)
    }

    @Test func aFrameTooShortForTheFieldsIsRefused() {
        #expect(MatroskaAC3Header(frame: Data([0x0B, 0x77, 0x02, 0xFF, 0x3F, 0x87])) == nil)
        #expect(MatroskaAC3Header(frame: Data([0x0B, 0x78, 0x02, 0xFF, 0x3F, 0x87, 0xC0])) == nil)
    }

    /// No encoder at hand writes fewer than six blocks, so the header is synthetic: the 5.1
    /// fixture's with `numblkscod` set to 1.
    @Test func aShortEAC3FrameIsTimedByItsBlockCount() throws {
        let twoBlocks = Data([0x0B, 0x77, 0x02, 0xFF, 0x1F, 0x87, 0xC0])
        let header = try #require(MatroskaAC3Header(frame: twoBlocks))

        #expect(header.blockCount == 2)
        #expect(header.channelLayoutTag == kAudioChannelLayoutTag_MPEG_5_1_C)

        let track = MatroskaTrack.audioStub(codecID: "A_EAC3", channelCount: 6)

        #expect(track.audioFramesPerPacket == nil)
        #expect(track.audioFrameCount(forPacket: twoBlocks) == 512)
        #expect(try track.makeAudioStreamBasicDescription(firstPacket: twoBlocks).mFramesPerPacket == 512)
    }

    /// With no packet, only the counts that cannot be ambiguous answer.
    @Test(arguments: [(1, kAudioChannelLayoutTag_Mono), (6, kAudioChannelLayoutTag_MPEG_5_1_C)])
    func withoutAPacketTheCountDecides(channelCount: Int, tag: AudioChannelLayoutTag) {
        #expect(MatroskaTrack.audioStub(codecID: "A_AC3", channelCount: channelCount).audioChannelLayoutTag() == tag)
    }

    @Test func anAmbiguousCountWithoutAPacketIsUnknown() {
        #expect(MatroskaTrack.audioStub(codecID: "A_AC3", channelCount: 4).audioChannelLayoutTag() == nil)
        #expect(MatroskaTrack.audioStub(codecID: "A_AAC", channelCount: 8).audioChannelLayoutTag() == nil)
    }
}

/// The format description is what both the PCM decoder and the video renderer are built from.
@Suite(.tags(.file))
struct MatroskaSurroundFormatDescriptionTests {
    @Test(arguments: [
        ("surround_eac3.mka", kAudioChannelLayoutTag_MPEG_5_1_C),
        ("surround_ac3.mka", kAudioChannelLayoutTag_MPEG_5_1_C),
        ("surround_aac.mka", kAudioChannelLayoutTag_MPEG_5_1_D),
        ("surround_flac.mka", kAudioChannelLayoutTag_MPEG_5_1_A),
        ("surround_opus.mka", kAudioChannelLayoutTag_Ogg_5_1),
    ])
    func surroundTracksCarryTheirLayout(name: String, tag: AudioChannelLayoutTag) throws {
        let url = try #require(TestBundleResources.shared.surroundFixtures.first { $0.lastPathComponent == name })
        let track = try #require(MatroskaFile(url: url).audioTrack)
        let packet = try MatroskaFrameReader.firstPacket(url: url, trackNumber: track.number)
        let description = try track.makeAudioFormatDescription(firstPacket: packet)

        var size = 0
        let layout = try #require(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size))
        #expect(layout.pointee.mChannelLayoutTag == tag)
    }

    @Test func surroundOpusCarriesItsChannelMapping() throws {
        let url = TestBundleResources.shared.surround_opus_mka
        let track = try #require(MatroskaFile(url: url).audioTrack)
        let description = try track.makeAudioFormatDescription()

        var size = 0
        _ = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &size)
        #expect(size == track.codecPrivate?.count)
        #expect(size > 0)
    }

    @Test func stereoCarriesNoLayout() throws {
        let track = try #require(MatroskaFile(url: TestBundleResources.shared.stereo_eac3_mka).audioTrack)
        let description = try track.makeAudioFormatDescription()

        #expect(CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil) == nil)
    }
}

extension MatroskaTrack {
    static func audioStub(codecID: String, channelCount: Int) -> MatroskaTrack {
        MatroskaTrack(
            number: 1,
            uid: 1,
            kind: .audio(AudioParameters(sampleRate: 48000, channelCount: channelCount, bitDepth: nil)),
            codecID: codecID,
            codecName: nil,
            name: nil,
            language: nil,
            codecPrivate: nil,
            defaultFrameDurationNanoseconds: nil,
            hasUnsupportedContentEncoding: false
        )
    }
}
