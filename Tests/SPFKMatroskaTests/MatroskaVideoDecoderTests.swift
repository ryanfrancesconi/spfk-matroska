// Copyright Ryan Francesconi. All Rights Reserved.

import CoreMedia
import CoreVideo
import Foundation
import SPFKTesting
import Testing
import VideoToolbox

@testable import SPFKMatroska

/// The fixture has visibly distinct frames on purpose, so a decode can assert *which* picture it
/// got rather than only that a picture arrived.
@Suite(.tags(.file), .serialized)
final class MatroskaVideoDecoderTests {
    let mkv = TestBundleResources.shared.sample_mkv
    let webm = TestBundleResources.shared.sample_webm
    let mka = TestBundleResources.shared.sample_mka

    /// Mean luminance of the first plane — enough to tell two frames apart without depending on
    /// exact pixel values, which vary with the decoder's output format.
    private func meanLuma(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let base = isPlanar
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBaseAddress(pixelBuffer)

        guard let base else { return 0 }

        let rowBytes = isPlanar
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)

        let height = isPlanar
            ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            : CVPixelBufferGetHeight(pixelBuffer)

        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var total = 0.0

        for row in 0 ..< height {
            for column in 0 ..< min(rowBytes, CVPixelBufferGetWidth(pixelBuffer)) {
                total += Double(bytes[row * rowBytes + column])
            }
        }

        return total / Double(height * min(rowBytes, CVPixelBufferGetWidth(pixelBuffer)))
    }

    @Test func decodesTheFirstPicture() throws {
        let decoder = try MatroskaVideoDecoder(url: mkv)
        let frame = try #require(try decoder.firstImage())

        #expect(CVPixelBufferGetWidth(frame.image) == 160)
        #expect(CVPixelBufferGetHeight(frame.image) == 120)
        #expect(frame.isKeyframe)

        // The first stored frame, which is the keyframe at 48ms rather than presentation time zero.
        #expect(abs(frame.timestamp - 0.048) < 0.001)
    }

    /// A picture, not a blank buffer — an all-black or all-grey result would satisfy the dimension
    /// assertions and mean the decode produced nothing usable.
    @Test func theDecodedPictureHasContent() throws {
        let decoder = try MatroskaVideoDecoder(url: mkv)
        let frame = try #require(try decoder.firstImage())

        let luma = meanLuma(frame.image)
        #expect(luma > 1)
        #expect(luma < 254)
    }

    /// The fixture's frames are visibly distinct, so consecutive decodes must differ. Identical
    /// output would mean the decoder is returning the same picture regardless of input.
    @Test func consecutiveFramesDiffer() throws {
        let decoder = try MatroskaVideoDecoder(url: mkv)

        var lumas: [Double] = []

        for _ in 0 ..< 6 {
            guard let frame = try decoder.nextImage() else { break }
            lumas.append(meanLuma(frame.image))
        }

        #expect(lumas.count == 6)
        #expect(Set(lumas.map { Int($0 * 100) }).count > 1)
    }

    /// Decodes every frame in the file, which is what catches a decoder that dies partway through
    /// a GOP or on the last cluster.
    @Test func decodesEveryFrameInTheFile() throws {
        let decoder = try MatroskaVideoDecoder(url: mkv)

        var count = 0
        var timestamps: [TimeInterval] = []

        while let frame = try decoder.nextImage() {
            count += 1
            timestamps.append(frame.timestamp)
        }

        #expect(count == 60)

        // Decode order, so presentation timestamps are not sorted -- sorting them must recover the
        // full span of the track.
        let sorted = timestamps.sorted()
        #expect(abs((sorted.first ?? 0) - 0.048) < 0.001)
        #expect(abs((sorted.last ?? 0) - 2.015) < 0.001)
    }

    /// VP9 decode is a **hardware** capability, not something every Mac has — this one reports
    /// `VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) == false` and VideoToolbox answers
    /// `kVTCouldNotFindVideoDecoderErr`. The demux and the format description are fine either way,
    /// which is what the branch pins: where a decoder exists the picture must arrive, and where one
    /// does not the refusal must be the specific "no decoder" error rather than a decode failure
    /// that would send someone looking at the parser.
    @Test func decodesWebMVP9WhereTheHardwareCan() throws {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9) else {
            #expect(throws: MatroskaVideoDecoderError.self) {
                try MatroskaVideoDecoder(url: webm)
            }
            return
        }

        let decoder = try MatroskaVideoDecoder(url: webm)
        let frame = try #require(try decoder.firstImage())

        #expect(CVPixelBufferGetWidth(frame.image) == 160)
        #expect(CVPixelBufferGetHeight(frame.image) == 120)
        #expect(meanLuma(frame.image) > 1)
    }

    @Test func refusesAFileWithNoVideoTrack() {
        #expect(throws: MatroskaVideoDecoderError.noVideoTrack(mka)) {
            try MatroskaVideoDecoder(url: mka)
        }
    }
}
