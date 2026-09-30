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
}
