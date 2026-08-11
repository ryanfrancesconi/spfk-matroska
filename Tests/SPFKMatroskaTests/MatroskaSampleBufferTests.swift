// Copyright Ryan Francesconi. All Rights Reserved.

import CoreMedia
import Foundation
import SPFKTesting
import Testing
import VideoToolbox

@testable import SPFKMatroska

/// Packaging demuxed frames for Core Media. A wrong format description produces objects that look
/// entirely correct until something tries to decode with them, so the load-bearing test here runs a
/// real frame through VideoToolbox rather than inspecting fields.
@Suite(.tags(.file), .serialized)
final class MatroskaSampleBufferTests {
    let mkv = TestBundleResources.shared.sample_mkv
    let webm = TestBundleResources.shared.sample_webm
    let mka = TestBundleResources.shared.sample_mka

    // MARK: - Format description

    @Test func buildsAFormatDescriptionFromCodecPrivate() throws {
        let track = try #require(try MatroskaFile(url: mkv).videoTrack)
        let formatDescription = try track.makeFormatDescription()

        #expect(CMFormatDescriptionGetMediaType(formatDescription) == kCMMediaType_Video)
        #expect(CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_H264)

        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
        #expect(dimensions.width == 160)
        #expect(dimensions.height == 120)
    }

    /// The `avcC` has to arrive verbatim — Matroska stores exactly the ISO-BMFF configuration box,
    /// which is why the demuxer hands the blob back untouched and nothing rewrites it.
    @Test func carriesTheCodecPrivateThroughAsAnAtom() throws {
        let track = try #require(try MatroskaFile(url: mkv).videoTrack)
        let formatDescription = try track.makeFormatDescription()

        let extensions = try #require(
            CMFormatDescriptionGetExtension(
                formatDescription,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Any]
        )

        let avcC = try #require(extensions["avcC"] as? Data)
        #expect(avcC == track.codecPrivate)
        #expect(avcC.first == 0x01)
    }

    /// VP9 carries its parameter sets in the bitstream and ships no `CodecPrivate`. Requiring one
    /// would reject every WebM file, so absence is only fatal for the codecs that need it.
    @Test func buildsAFormatDescriptionForACodecWithNoCodecPrivate() throws {
        let track = try #require(try MatroskaFile(url: webm).videoTrack)

        #expect(track.codecPrivate == nil)

        let formatDescription = try track.makeFormatDescription()
        #expect(CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_VP9)
    }

    @Test func refusesANonVideoTrack() throws {
        let track = try #require(try MatroskaFile(url: mka).audioTrack)

        #expect(throws: MatroskaSampleBufferError.missingVideoParameters) {
            try track.makeFormatDescription()
        }
    }

    // MARK: - Decodability

    @Test func reportsDecodableForCodecsWithADecoder() throws {
        #expect(try #require(try MatroskaFile(url: mkv).videoTrack).isDecodable)
        #expect(try #require(try MatroskaFile(url: webm).videoTrack).isDecodable)
    }

    /// **A fourCC that maps is not a decoder.** `V_AV1` resolves to `kCMVideoCodecType_AV1` and has
    /// no decoder on most machines, so a check that stops at the codec table reports it decodable
    /// and the caller gets a black frame instead of an unsupported-format message.
    @Test func reportsUndecodableForACodecWithNoDecoder() {
        #expect(MatroskaTrack.videoStub(codecID: "V_AV1").isDecodable == false)
    }

    /// A codec outside the table at all, which is the other way a video track fails.
    @Test func reportsUndecodableForACodecOutsideTheTable() {
        #expect(MatroskaTrack.videoStub(codecID: "V_VP8").isDecodable == false)
    }

    /// H.264 keeps its parameter sets out of band, so a track with no `CodecPrivate` cannot be
    /// described and therefore cannot be decoded — undecodable rather than a thrown error.
    @Test func reportsUndecodableForH264WithNoCodecPrivate() {
        #expect(MatroskaTrack.videoStub(codecID: "V_MPEG4/ISO/AVC").isDecodable == false)
    }

    // MARK: - Sample buffers

    @Test func buildsASampleBufferWithMatroskaTiming() throws {
        let reader = try MatroskaFrameReader(url: mkv)
        let track = try #require(reader.file.videoTrack)
        let formatDescription = try track.makeFormatDescription()

        let frame = try #require(try reader.allFrames(ofTrack: track.number).first)
        let sampleBuffer = try frame.makeSampleBuffer(formatDescription: formatDescription)

        #expect(CMSampleBufferIsValid(sampleBuffer))
        #expect(CMSampleBufferGetNumSamples(sampleBuffer) == 1)
        #expect(CMSampleBufferGetTotalSampleSize(sampleBuffer) == frame.data.count)

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        #expect(abs(presentationTime.seconds - 0.048) < 0.0001)

        // Matroska has no container-level DTS and frames already arrive in decode order, so
        // inventing one would either duplicate that ordering or contradict it.
        #expect(CMSampleBufferGetDecodeTimeStamp(sampleBuffer) == .invalid)
    }

    /// Absence of the attachment means *sync*, so only non-keyframes need marking. Getting this
    /// backwards makes a decoder try to start on a P-frame.
    @Test func marksOnlyNonKeyframesAsNotSync() throws {
        let reader = try MatroskaFrameReader(url: mkv)
        let track = try #require(reader.file.videoTrack)
        let formatDescription = try track.makeFormatDescription()

        let frames = try reader.allFrames(ofTrack: track.number)

        let keyframe = try #require(frames.first { $0.isKeyframe })
        let other = try #require(frames.first { $0.isKeyframe == false })

        #expect(notSyncFlag(of: try keyframe.makeSampleBuffer(formatDescription: formatDescription)) != true)
        #expect(notSyncFlag(of: try other.makeSampleBuffer(formatDescription: formatDescription)) == true)
    }

    private func notSyncFlag(of sampleBuffer: CMSampleBuffer) -> Bool? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0
        else {
            return nil
        }

        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFDictionary.self)

        return (dictionary as? [CFString: Any])?[kCMSampleAttachmentKey_NotSync] as? Bool
    }

    // MARK: - Decoding

    /// **The one that matters.** Everything above inspects objects this code built, which proves
    /// only self-consistency. This hands one to VideoToolbox and requires a picture back — the
    /// first thing that would fail if the `avcC` were mangled, the dimensions wrong, or the frame
    /// data in the wrong NAL format.
    @Test func aFrameDecodesThroughVideoToolbox() throws {
        let reader = try MatroskaFrameReader(url: mkv)
        let track = try #require(reader.file.videoTrack)
        let formatDescription = try track.makeFormatDescription()

        var session: VTDecompressionSession?

        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        #expect(sessionStatus == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }

        let keyframe = try #require(try reader.allFrames(ofTrack: track.number).first { $0.isKeyframe })
        let sampleBuffer = try keyframe.makeSampleBuffer(formatDescription: formatDescription)

        let result = DecodeResult()

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            decoder,
            sampleBuffer: sampleBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            result.status = status
            result.imageBuffer = imageBuffer
        }

        #expect(decodeStatus == noErr)
        #expect(VTDecompressionSessionWaitForAsynchronousFrames(decoder) == noErr)

        #expect(result.status == noErr)

        let image = try #require(result.imageBuffer)
        #expect(CVPixelBufferGetWidth(image) == 160)
        #expect(CVPixelBufferGetHeight(image) == 120)
    }

    /// The decode handler is invoked on VideoToolbox's own thread, so the result crosses a
    /// concurrency boundary; the test waits on it before reading.
    private final class DecodeResult: @unchecked Sendable {
        var status: OSStatus = noErr
        var imageBuffer: CVImageBuffer?
    }
}

private extension MatroskaTrack {
    /// A video track carrying nothing but a `CodecID` and a frame size, for asking what a codec
    /// alone can support.
    static func videoStub(codecID: String) -> MatroskaTrack {
        MatroskaTrack(
            number: 1,
            uid: 1,
            kind: .video(
                VideoParameters(
                    pixelWidth: 160,
                    pixelHeight: 120,
                    displayWidth: 0,
                    displayHeight: 0,
                    displayUnit: .pixels,
                    declaredFrameRate: nil
                )
            ),
            codecID: codecID,
            codecName: nil,
            name: nil,
            language: nil,
            codecPrivate: nil,
            defaultFrameDurationNanoseconds: nil
        )
    }
}
