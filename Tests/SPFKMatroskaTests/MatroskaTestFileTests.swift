// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

extension MatroskaTestFile {
    /// Writes the file to a unique temporary URL; the caller removes it.
    func writeTemporary(pathExtension: String = "mkv") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spfk-matroska-test-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        try write(to: url)
        return url
    }
}

/// Proves the writer against libwebm, so the suites built on it are testing the reader rather than
/// the writer.
@Suite(.tags(.file), .serialized)
final class MatroskaTestFileTests {
    private static func payload(_ cluster: Int, _ block: Int, _ frame: Int = 0) -> Data {
        Data([UInt8(cluster), UInt8(block), UInt8(frame), 0xAB])
    }

    private let file = MatroskaTestFile(
        tracks: [
            .video(number: 1, uid: 11, codecID: "V_TEST", width: 64, height: 48),
            .pcm(number: 2, uid: 22, sampleRate: 48000, channels: 2),
        ],
        clusters: (0 ..< 3).map { index in
            MatroskaTestFile.Cluster(timecode: UInt64(index) * 100, blocks: [
                .init(track: 1, relativeTimecode: 0, keyframe: true, frames: [MatroskaTestFileTests.payload(index, 0)]),
                .init(track: 2, relativeTimecode: 0, frames: [MatroskaTestFileTests.payload(index, 1)]),
                .init(track: 1, relativeTimecode: 40, keyframe: false, frames: [MatroskaTestFileTests.payload(index, 2)]),
                .init(track: 2, relativeTimecode: 50, frames: (0 ..< 3).map { MatroskaTestFileTests.payload(index, 3, $0) }),
            ])
        },
        cues: (0 ..< 3).map { .init(time: UInt64($0) * 100, track: 1, clusterIndex: $0) }
    )

    @Test func tracksReadBackAsWritten() throws {
        let url = try file.writeTemporary()
        defer { try? FileManager.default.removeItem(at: url) }

        let matroska = try MatroskaFile(url: url)

        #expect(matroska.timecodeScale == 1_000_000)
        #expect(matroska.tracks.map(\.number) == [1, 2])
        #expect(matroska.tracks.map(\.uid) == [11, 22])
        #expect(matroska.tracks.map(\.codecID) == ["V_TEST", "A_PCM/INT/LIT"])
        #expect(matroska.videoTrack?.kind == .video(.init(
            pixelWidth: 64, pixelHeight: 48, displayWidth: 64, displayHeight: 48, displayUnit: .pixels, declaredFrameRate: nil
        )))
        #expect(matroska.audioTrack?.kind == .audio(.init(sampleRate: 48000, channelCount: 2, bitDepth: 16)))
    }

    @Test func framesReadBackAsWritten() throws {
        let url = try file.writeTemporary()
        defer { try? FileManager.default.removeItem(at: url) }

        var expected: [MatroskaFrame] = []

        for cluster in file.clusters {
            for block in cluster.blocks {
                let time = TimeInterval(Int64(cluster.timecode) + Int64(block.relativeTimecode)) / 1000

                for frame in block.frames {
                    expected.append(MatroskaFrame(
                        trackNumber: Int(block.track), data: frame, timestamp: time, duration: nil, isKeyframe: block.keyframe
                    ))
                }
            }
        }

        #expect(try MatroskaFrameReader(url: url).allFrames() == expected)
    }

    @Test func clusterOffsetsPointAtClusterIDs() throws {
        let data = file.data()
        let clusterID = Data([0x1F, 0x43, 0xB6, 0x75])

        for offset in file.clusterOffsets {
            #expect(data[offset ..< offset + 4] == clusterID)
        }
    }

    @Test func seeksThroughTheCues() throws {
        let url = try file.writeTemporary()
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try MatroskaFrameReader(url: url)
        try reader.seek(to: 0.15, trackNumber: 1)

        let first = try #require(try reader.nextFrame())
        #expect(first.data == Self.payload(1, 0))
    }
}
