// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import Testing

@testable import SPFKMatroska

/// A file cut short — a crashed recording — reads up to where it stops.
@Suite(.tags(.file), .serialized)
final class MatroskaTruncationTests {
    private func temporaryCopy(of data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spfk-matroska-cut-\(UUID().uuidString).mka")
        try data.write(to: url)
        return url
    }

    /// Three clusters of four PCM blocks, every frame's bytes unique so each can be found in the file.
    private let file = MatroskaTestFile(
        tracks: [.pcm(number: 1, uid: 1)],
        clusters: (0 ..< 3).map { cluster in
            MatroskaTestFile.Cluster(timecode: UInt64(cluster) * 100, blocks: (0 ..< 4).map { block in
                MatroskaTestFile.Block(
                    track: 1,
                    relativeTimecode: Int16(block * 10),
                    frames: [Data([UInt8(cluster), UInt8(block)] + [UInt8](repeating: 0x5A, count: 98))]
                )
            })
        }
    )

    @Test func readsATruncatedOneClusterFileUpToTheCut() throws {
        let source = TestBundleResources.shared.tabla_mka
        let intact = try MatroskaFrameReader(url: source).allFrames()
        let data = try Data(contentsOf: source)

        let kept = data.count * 97 / 100
        let url = try temporaryCopy(of: data.prefix(kept))
        defer { try? FileManager.default.removeItem(at: url) }

        // The frames whose bytes the cut removes, plus the one it splits.
        var removed = 0
        var lost = 0

        for frame in intact.reversed() where removed < data.count - kept {
            removed += frame.data.count
            lost += 1
        }

        let truncated = try MatroskaFrameReader(url: url).allFrames()

        #expect(truncated.count >= intact.count - (lost + 1))
        #expect(truncated == Array(intact.prefix(truncated.count)))
    }

    @Test func readsEveryClusterBeforeTheCut() throws {
        let data = file.data()
        let thirdCluster = file.clusterOffsets[2]
        let cut = thirdCluster + (data.count - thirdCluster) / 2

        let url = try temporaryCopy(of: data.prefix(cut))
        defer { try? FileManager.default.removeItem(at: url) }

        let complete = file.clusters[2].blocks.flatMap(\.frames).filter { frame in
            guard let range = data.range(of: frame) else { return false }
            return range.upperBound <= cut
        }

        let frames = try MatroskaFrameReader(url: url).allFrames()

        #expect(frames.count == 8 + complete.count)
        #expect(frames.suffix(complete.count).map(\.data) == complete)
    }

    @Test func aCutAtAClusterBoundaryReadsTheClustersBeforeIt() throws {
        let url = try temporaryCopy(of: file.data().prefix(file.clusterOffsets[2]))
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try MatroskaFrameReader(url: url)

        #expect(try reader.allFrames().count == 8)
        #expect(reader.isTruncated)
    }

    @Test func reportsTheCut() throws {
        let tabla = TestBundleResources.shared.tabla_mka
        let tablaData = try Data(contentsOf: tabla)
        let cutTabla = try temporaryCopy(of: tablaData.prefix(tablaData.count * 97 / 100))
        let intact = try temporaryCopy(of: file.data())
        let cut = try temporaryCopy(of: file.data().prefix(file.clusterOffsets[2] + 30))

        defer {
            for url in [cutTabla, intact, cut] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        #expect(try MatroskaFrameReader(url: cutTabla).isTruncated)
        #expect(try MatroskaFrameReader(url: cut).isTruncated)
        #expect(try !MatroskaFrameReader(url: tabla).isTruncated)
        #expect(try !MatroskaFrameReader(url: intact).isTruncated)
    }

    /// A segment of unknown size cannot say it was cut, but its last cluster still reads to the cut.
    @Test func readsAnUnknownSizeClusterUpToTheCut() throws {
        var unknown = file
        unknown.segmentSizeIsUnknown = true
        unknown.clusters[2].sizeIsUnknown = true

        let data = unknown.data()
        let thirdCluster = unknown.clusterOffsets[2]
        let cut = thirdCluster + (data.count - thirdCluster) / 2

        let url = try temporaryCopy(of: data.prefix(cut))
        defer { try? FileManager.default.removeItem(at: url) }

        let complete = unknown.clusters[2].blocks.flatMap(\.frames).filter { frame in
            guard let range = data.range(of: frame) else { return false }
            return range.upperBound <= cut
        }

        let reader = try MatroskaFrameReader(url: url)
        let frames = try reader.allFrames()

        #expect(frames.count == 8 + complete.count)
        #expect(!reader.isTruncated)
    }
}
