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

    /// The still-preview path: one picture out of a container AVFoundation will not open, without
    /// the caller running a decode loop.
    @Test func producesACGImageForAStillPreview() throws {
        let image = try #require(try MatroskaVideoDecoder.firstCGImage(url: mkv))

        #expect(image.width == 160)
        #expect(image.height == 120)
    }

    @Test func refusesAFileWithNoVideoTrack() {
        #expect(throws: MatroskaVideoDecoderError.noVideoTrack(mka)) {
            try MatroskaVideoDecoder(url: mka)
        }
    }

    /// The poster frame both products call, sampled at the shared midpoint rule rather than at
    /// frame zero — the difference between a thumbnail and a black rectangle.
    @Test func posterFrameComesFromTheMidpointNotTheOpening() throws {
        let poster = try #require(MatroskaVideoDecoder.posterCGImage(url: mkv))
        let opening = try #require(try MatroskaVideoDecoder.firstCGImage(url: mkv))

        #expect(poster.width == 160)
        #expect(poster.height == 120)
        #expect(poster.dataProvider?.data != opening.dataProvider?.data)
    }

    /// A container this package does not handle is the *expected* input on the fallback path both
    /// products use, so it answers nil quietly rather than logging an error for every MP4 that
    /// reaches it.
    @Test func posterFrameIsNilForANonMatroskaFile() {
        #expect(MatroskaVideoDecoder.posterCGImage(url: TestBundleResources.shared.sample_mov) == nil)
    }

    /// Audio-only Matroska is a real file this can be handed; there is simply no picture in it.
    @Test func posterFrameIsNilForAFileWithNoVideoTrack() {
        #expect(MatroskaVideoDecoder.posterCGImage(url: mka) == nil)
    }
}

// MARK: - Seeking

@Suite(.tags(.file), .serialized)
final class MatroskaSeekTests {
    let mkv = TestBundleResources.shared.sample_mkv

    /// A seek must land on a keyframe at or **before** the requested time — never after, or the
    /// decoder starts mid-GOP with no reference frames and produces garbage.
    @Test func seekLandsOnTheKeyframeAtOrBeforeTheRequest() throws {
        let reader = try MatroskaFrameReader(url: mkv)
        let track = try #require(reader.file.videoTrack)

        try reader.seek(to: 1.5, trackNumber: track.number)

        let frame = try #require(try reader.allFrames(ofTrack: track.number).first)

        #expect(frame.isKeyframe)
        #expect(frame.timestamp <= 1.5)
    }

    /// Verified against the Cues index rather than against itself: the fixture keyframes every 15
    /// frames at 30fps, so seeking past the second one must not come back with the first.
    @Test func seekingForwardAdvancesPastEarlierKeyframes() throws {
        let reader = try MatroskaFrameReader(url: mkv)
        let track = try #require(reader.file.videoTrack)

        let allKeyframes = try reader.allFrames(ofTrack: track.number)
            .filter(\.isKeyframe)
            .map(\.timestamp)
            .sorted()

        #expect(allKeyframes.count == 4)

        let target = try #require(allKeyframes.last)

        let seeking = try MatroskaFrameReader(url: mkv)
        try seeking.seek(to: target + 0.01, trackNumber: track.number)

        let landed = try #require(try seeking.allFrames(ofTrack: track.number).first)
        #expect(abs(landed.timestamp - target) < 0.001)
    }

    /// The point of the whole exercise: a picture from the middle of the file without decoding
    /// everything before it.
    @Test func decodesAPictureAfterSeeking() throws {
        let image = try #require(try MatroskaVideoDecoder.cgImage(url: mkv, at: 1.5))

        #expect(image.width == 160)
        #expect(image.height == 120)
    }

    /// A midpoint poster must differ from the opening frame, which is the visible symptom that
    /// started this: every film thumbnail was black because it was frame zero.
    @Test func aMidpointPosterDiffersFromTheFirstFrame() throws {
        let first = try #require(try MatroskaVideoDecoder.firstCGImage(url: mkv))
        let middle = try #require(try MatroskaVideoDecoder.cgImage(url: mkv, at: 1.0))

        #expect(first.width == middle.width)
        #expect(first.dataProvider?.data != middle.dataProvider?.data)
    }

    /// The layout real muxers write: the `SeekHead` at the head of the file names a second one
    /// rather than naming `Cues`. libwebm keeps only the first `SeekHead` and never follows a
    /// nested entry, so reading no further finds no index at all and the seek falls back to the
    /// start of the file — indistinguishable from working, and black on anything that opens dark.
    @Test func seeksInAFileWhoseSeekHeadIsNested() throws {
        let url = TestBundleResources.shared.sample_nested_seekhead_mkv
        let reader = try MatroskaFrameReader(url: url)
        let track = try #require(reader.file.videoTrack)

        try reader.seek(to: 1.5, trackNumber: track.number)

        let frame = try #require(try reader.allFrames(ofTrack: track.number).first)

        #expect(frame.isKeyframe)
        #expect(abs(frame.timestamp - 1.048) < 0.001)
    }

    /// Each cue point names one track and the audio ones fall between the video keyframes, so the
    /// cue point nearest 1.5 s is the 1300 ms *audio* one. Matching by time and then asking that
    /// point for the video track finds nothing and abandons the seek; the track has to stay in the
    /// search, which lands on the 1048 ms keyframe.
    @Test func seeksVideoInAFileWhoseCuePointsInterleave() throws {
        let url = TestBundleResources.shared.sample_interleaved_cues_mkv
        let reader = try MatroskaFrameReader(url: url)
        let track = try #require(reader.file.videoTrack)

        try reader.seek(to: 1.5, trackNumber: track.number)

        let frame = try #require(try reader.allFrames(ofTrack: track.number).first)

        #expect(frame.isKeyframe)
        #expect(abs(frame.timestamp - 1.048) < 0.001)
    }
}
