// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// A crafted file whose block times overflow stops with a read error rather than yielding frames at
/// nonsense times.
@Suite(.tags(.file), .serialized)
final class MatroskaMalformedTimingTests {
    @Test func aBlockTimeBeyondNanosecondsThrows() throws {
        let file = MatroskaTestFile(
            timecodeScale: 1 << 62,
            tracks: [.pcm(number: 1, uid: 1)],
            clusters: [.init(timecode: 4, blocks: [.init(track: 1, frames: [Data(repeating: 0, count: 4)])])]
        )

        let url = try file.writeTemporary(pathExtension: "mka")
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try MatroskaFrameReader(url: url)

        #expect(throws: MatroskaError.malformedSegment(url)) {
            try reader.nextFrame()
        }
    }

    @Test func aLaceOffsetBeyondNanosecondsThrows() throws {
        var track = MatroskaTestFile.Track.pcm(number: 1, uid: 1)
        track.defaultDuration = UInt64(Int64.max)

        let file = MatroskaTestFile(
            tracks: [track],
            clusters: [.init(timecode: 1, blocks: [.init(track: 1, frames: [Data(repeating: 0, count: 4), Data(repeating: 1, count: 4)])])]
        )

        let url = try file.writeTemporary(pathExtension: "mka")
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try MatroskaFrameReader(url: url)
        let first = try reader.nextFrame()

        #expect(first?.timestamp == 0.001)
        #expect(throws: MatroskaError.malformedSegment(url)) {
            try reader.nextFrame()
        }
    }

    /// libwebm reports a block before the segment start as -1 ns too; that stays readable.
    @Test func aBlockBeforeTheSegmentStartIsStillRead() throws {
        let file = MatroskaTestFile(
            tracks: [.pcm(number: 1, uid: 1)],
            clusters: [.init(timecode: 0, blocks: [
                .init(track: 1, relativeTimecode: -5, frames: [Data(repeating: 0, count: 4)]),
                .init(track: 1, relativeTimecode: 5, frames: [Data(repeating: 1, count: 4)]),
            ])]
        )

        let url = try file.writeTemporary(pathExtension: "mka")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try MatroskaFrameReader(url: url).allFrames().count == 2)
    }
}
