// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// A track can declare every frame transformed before storage; only header stripping is undone.
@Suite(.tags(.file), .serialized)
final class MatroskaContentEncodingTests {
    private static let prefix = Data([0x11, 0x22])

    private static let payloads = (0 ..< 4).map { index in
        prefix + Data([UInt8(index), 0x33, 0x44, UInt8(index)])
    }

    @Test func strippedHeadersAreRestored() throws {
        var track = MatroskaTestFile.Track.pcm(number: 1, uid: 1)
        track.contentEncoding = .headerStripping(Self.prefix)

        let file = MatroskaTestFile(
            tracks: [track],
            clusters: [.init(timecode: 0, blocks: Self.payloads.enumerated().map { index, payload in
                .init(track: 1, relativeTimecode: Int16(index), frames: [payload.dropFirst(Self.prefix.count)])
            })]
        )

        let url = try file.writeTemporary(pathExtension: "mka")
        defer { try? FileManager.default.removeItem(at: url) }

        let frames = try MatroskaFrameReader(url: url).allFrames().map(\.data)

        #expect(frames == Self.payloads)
    }

    private func track(encodedWith encoding: MatroskaTestFile.ContentEncoding, video: Bool = false) throws -> MatroskaTrack {
        var track: MatroskaTestFile.Track = video
            ? .video(number: 1, uid: 1, codecID: "V_MPEG4/ISO/AVC")
            : .pcm(number: 1, uid: 1)
        track.contentEncoding = encoding

        let file = MatroskaTestFile(
            tracks: [track],
            clusters: [.init(timecode: 0, blocks: [.init(track: 1, frames: [Data(repeating: 0, count: 8)])])]
        )

        let url = try file.writeTemporary(pathExtension: video ? "mkv" : "mka")
        defer { try? FileManager.default.removeItem(at: url) }

        return try #require(try MatroskaFile(url: url).tracks.first)
    }

    @Test(arguments: [
        MatroskaTestFile.ContentEncoding.zlib(),
        .encrypted(),
        .headerStripping(Data([0x11, 0x22]), scope: 3),
    ])
    func anEncodingThatCannotBeUndoneIsNotDecodable(encoding: MatroskaTestFile.ContentEncoding) throws {
        let track = try track(encodedWith: encoding)

        #expect(track.hasUnsupportedContentEncoding)
        #expect(track.isDecodable == false)
        #expect(throws: MatroskaSampleBufferError.unsupportedContentEncoding(codecID: "A_PCM/INT/LIT")) {
            try track.makeAudioStreamBasicDescription()
        }
    }

    /// libwebm drops an encryption entry it cannot parse, leaving the track looking unencoded.
    @Test func anEncodingTheParserDropsIsNotDecodable() throws {
        var track = MatroskaTestFile.Track.pcm(number: 1, uid: 1)
        track.contentEncoding = .encrypted()

        var data = MatroskaTestFile(
            tracks: [track],
            clusters: [.init(timecode: 0, blocks: [.init(track: 1, frames: [Data(repeating: 0, count: 8)])])]
        ).data()

        // `ContentEncAlgo` 5 becomes 1, an algorithm libwebm refuses.
        let algorithm = Data([0x47, 0xE1, 0x01, 0, 0, 0, 0, 0, 0, 0x01, 0x05])
        let range = try #require(data.range(of: algorithm))
        data[range.upperBound - 1] = 0x01

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spfk-matroska-enc-\(UUID().uuidString).mka")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let parsed = try #require(try MatroskaFile(url: url).tracks.first)

        #expect(parsed.isDecodable == false)
    }

    @Test func anUnencodedTrackIsDecodable() throws {
        let file = MatroskaTestFile(
            tracks: [.pcm(number: 1, uid: 1)],
            clusters: [.init(timecode: 0, blocks: [.init(track: 1, frames: [Data(repeating: 0, count: 8)])])]
        )

        let url = try file.writeTemporary(pathExtension: "mka")
        defer { try? FileManager.default.removeItem(at: url) }

        let track = try #require(try MatroskaFile(url: url).tracks.first)

        #expect(track.hasUnsupportedContentEncoding == false)
        #expect(track.isDecodable)
    }

    /// Refused before the codec is looked at, so no valid `avcC` is needed.
    @Test func aCompressedVideoTrackIsRefusedForItsEncoding() throws {
        let track = try track(encodedWith: .zlib(), video: true)

        #expect(throws: MatroskaSampleBufferError.unsupportedContentEncoding(codecID: "V_MPEG4/ISO/AVC")) {
            try track.makeFormatDescription()
        }
    }
}
