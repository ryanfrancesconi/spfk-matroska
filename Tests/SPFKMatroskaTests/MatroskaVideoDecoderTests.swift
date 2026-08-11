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

    /// VP9 decodes, which needs ``SupplementalVideoDecoders`` to have registered — the decoder is
    /// not in a process that never asked for it, and its absence reads exactly like a machine with
    /// no VP9 hardware.
    @Test func decodesWebMVP9() throws {
        let decoder = try MatroskaVideoDecoder(url: webm)
        let frame = try #require(try decoder.firstImage())

        #expect(CVPixelBufferGetWidth(frame.image) == 160)
        #expect(CVPixelBufferGetHeight(frame.image) == 120)
        #expect(meanLuma(frame.image) > 1)
    }

    /// The registration itself, asserted where it is visible: VideoToolbox reports no VP9 hardware
    /// until asked for the decoder.
    ///
    /// One-directional on purpose — registration is process-global and another test may have run
    /// first, so this can only assert the state that holds afterwards.
    @Test func registeringSupplementalDecodersMakesVP9Available() {
        SupplementalVideoDecoders.register()

        #expect(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9))
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

// MARK: - Filmstrip

@Suite(.tags(.file), .serialized)
struct MatroskaFilmstripTests {
    private let mkv = TestBundleResources.shared.sample_mkv

    /// The filmstrip's whole point: several stills from one open of the file, keyed by the time
    /// that was asked for so an evenly spaced request draws evenly spaced.
    @Test func extractsAFrameForEachRequestedTimestamp() throws {
        let timestamps: [TimeInterval] = [0.1, 0.6, 1.1, 1.6]

        let images = try MatroskaVideoDecoder.cgImages(url: mkv, at: timestamps)

        #expect(images.count == timestamps.count)
        for timestamp in timestamps {
            #expect(images[timestamp] != nil)
        }
    }

    /// Different points in the file must give different pictures — the failure this guards is a
    /// strip of one frame repeated, which a count check alone would pass.
    @Test func framesAtDifferentTimesDiffer() throws {
        let images = try MatroskaVideoDecoder.cgImages(url: mkv, at: [0.1, 1.6])

        let first = try #require(images[0.1]?.dataProvider?.data)
        let last = try #require(images[1.6]?.dataProvider?.data)

        #expect(first != last)
    }

    /// A filmstrip tile is small; a native-resolution frame would be held per tile.
    @Test func framesAreBoundedByTheRequestedSize() throws {
        let images = try MatroskaVideoDecoder.cgImages(url: mkv, at: [0.5], maximumSize: 40)
        let image = try #require(images[0.5])

        #expect(max(image.width, image.height) <= 40)
        // 160x120 scaled to a 40pt longest edge keeps 4:3.
        #expect(image.width == 40)
        #expect(image.height == 30)
    }

    @Test func noTimestampsIsNotAnError() throws {
        #expect(try MatroskaVideoDecoder.cgImages(url: mkv, at: []).isEmpty)
    }
}

/// The filmstrip path: many pictures from one file, which is what a timeline band asks for.
@Suite(.tags(.file), .serialized)
struct MatroskaVideoDecoderImagesTests {
    let mkv = TestBundleResources.shared.sample_mkv

    @Test func returnsAPictureForEachRequestedTimestamp() throws {
        let duration = try #require(MatroskaFile(url: mkv).duration)
        try #require(duration > 0)

        // Ends strictly before the duration, so every request is reachable.
        let timestamps = stride(from: 0.0, to: duration, by: duration / 4).map { $0 }
        try #require(timestamps.count >= 3)

        let images = try MatroskaVideoDecoder.cgImages(url: mkv, at: timestamps)

        #expect(images.count == timestamps.count, "asked for \(timestamps.count) frames, got \(images.count)")

        for timestamp in timestamps {
            #expect(images[timestamp] != nil, "no picture at \(timestamp)s")
        }
    }

    /// The bound that keeps a feature-length filmstrip from costing gigabytes.
    @Test func scalesEachPictureWithinTheGivenSize() throws {
        let band: CGFloat = 44

        let images = try MatroskaVideoDecoder.cgImages(url: mkv, at: [0], maximumSize: band)

        let image = try #require(images[0])

        #expect(max(image.width, image.height) == Int(band), "scaled to \(image.width)x\(image.height)")
        #expect(image.width > 0)
    }

    /// The streaming contract: every returned frame is also delivered as it decodes, in order.
    ///
    /// This is what lets a filmstrip fill in during the scan instead of appearing at the end, so a
    /// callback that stopped firing would look like a hang rather than a failure.
    @Test func deliversEachPictureAsItIsDecoded() throws {
        let duration = try #require(MatroskaFile(url: mkv).duration)

        let timestamps = stride(from: 0.0, to: duration, by: duration / 4).map { $0 }
        try #require(timestamps.count >= 3)

        var delivered: [TimeInterval] = []

        let images = try MatroskaVideoDecoder.cgImages(url: mkv, at: timestamps) { timestamp, _ in
            delivered.append(timestamp)
        }

        #expect(delivered.count == images.count, "delivered \(delivered.count) of \(images.count) frames")
        #expect(delivered == delivered.sorted(), "frames arrived out of order: \(delivered)")
    }

    /// Unsorted input must not lose frames: the walk only moves forward, so the method sorts.
    @Test func acceptsTimestampsInAnyOrder() throws {
        let duration = try #require(MatroskaFile(url: mkv).duration)

        let timestamps = [duration / 2, 0, duration / 4]

        let images = try MatroskaVideoDecoder.cgImages(url: mkv, at: timestamps)

        #expect(images.count == timestamps.count)
    }
}

/// Which positions the cue index can actually reach, at reader level.
@Suite(.tags(.file), .serialized, .enabled(if: ProcessInfo.processInfo.environment["SPFK_LONG_MEDIA"] != nil))
struct MatroskaLongFileReaderSeekTests {
    @Test func reportsSeekableRange() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SPFK_LONG_MEDIA"])
        let url = URL(fileURLWithPath: path)

        let file = try MatroskaFile(url: url)
        let duration = try #require(file.duration)
        let audio = try #require(file.audioTrack)
        let video = file.videoTrack

        print("📏 duration \(Int(duration))s  audio track \(audio.number)  video track \(video?.number ?? -1)")

        for fraction in stride(from: 0.0, through: 0.9, by: 0.1) {
            let target = duration * fraction
            let reader = try MatroskaFrameReader(url: url)

            do {
                try reader.seek(to: target, trackNumber: audio.number)

                var first: MatroskaFrame?
                var scanned = 0

                while let frame = try reader.nextFrame(), scanned < 200 {
                    scanned += 1
                    if frame.trackNumber == audio.number {
                        first = frame
                        break
                    }
                }

                if let first {
                    print("✅ \(Int(target))s -> audio at \(String(format: "%.2f", first.timestamp))s after \(scanned) frames")
                } else {
                    print("⚠️ \(Int(target))s -> no audio frame in \(scanned) frames")
                }

            } catch {
                print("❌ \(Int(target))s -> \(error)")
            }
        }
    }
}
