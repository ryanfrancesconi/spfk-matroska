// Copyright Ryan Francesconi. All Rights Reserved.

import AVFoundation
import CoreMedia
import Foundation
import SPFKTesting
import Testing
import VideoToolbox

@testable import SPFKMatroska

/// Who is responsible for turning stored order into display order.
///
/// `sample.mkv` carries B-frames, so the order frames are stored in is not the order they are shown
/// in. These pin *where* that is resolved, because writing a reorder buffer when the system already
/// has one would be inventing work — and writing one in the wrong place would be worse.
@Suite(.tags(.file), .serialized)
struct MatroskaDisplayOrderTests {
    private let mkv = TestBundleResources.shared.sample_mkv

    /// Every video sample buffer in the file, in stored order.
    private func sampleBuffers() throws -> (buffers: [CMSampleBuffer], track: MatroskaTrack) {
        let reader = try MatroskaFrameReader(url: mkv)
        let track = try #require(reader.file.videoTrack)
        let formatDescription = try track.makeFormatDescription()

        var buffers: [CMSampleBuffer] = []

        while let frame = try reader.nextFrame() {
            guard frame.trackNumber == track.number, frame.data.isEmpty == false else { continue }
            buffers.append(try frame.makeSampleBuffer(formatDescription: formatDescription))
        }

        return (buffers, track)
    }

    /// Stored order is decode order, and for this file that is **not** ascending presentation time.
    /// The fixture would not exercise any of this if it were.
    @Test func storedOrderIsNotPresentationOrder() throws {
        let timestamps = try sampleBuffers().buffers.map(\.presentationTimeStamp.seconds)

        #expect(timestamps.count == 60)
        #expect(timestamps != timestamps.sorted())
    }

    /// **`VTDecompressionSession` will not reorder these, even asked to.** Temporal processing is
    /// VideoToolbox's own reordering, and it stays inert here because the sample buffers carry no
    /// decode timestamp — `CMSampleTimingInfo.decodeTimeStamp` is `.invalid`, deliberately, since
    /// Matroska stores no container-level DTS.
    ///
    /// Recorded as a test rather than a comment because it is the fact that decides the design: a
    /// pull-based decoder that had to emit presentation order would need synthesized decode
    /// timestamps first. Nothing needs that today — see the display-layer test below — and this
    /// fails loudly if a future OS starts reordering without them, which would mean the constraint
    /// has lifted.
    @Test func videoToolboxDoesNotReorderWithoutDecodeTimestamps() throws {
        let (buffers, track) = try sampleBuffers()

        var session: VTDecompressionSession?

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: try track.makeFormatDescription(),
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        #expect(status == noErr)
        let created = try #require(session)
        defer { VTDecompressionSessionInvalidate(created) }

        let collector = TimestampCollector()

        for buffer in buffers {
            VTDecompressionSessionDecodeFrame(
                created,
                sampleBuffer: buffer,
                flags: [._EnableAsynchronousDecompression, ._EnableTemporalProcessing],
                infoFlagsOut: nil
            ) { _, _, imageBuffer, presentationTimeStamp, _ in
                guard imageBuffer != nil else { return }
                collector.append(presentationTimeStamp.seconds)
            }
        }

        VTDecompressionSessionFinishDelayedFrames(created)
        VTDecompressionSessionWaitForAsynchronousFrames(created)

        #expect(collector.timestamps.count == 60)
        #expect(collector.timestamps != collector.timestamps.sorted())
    }
}

// MARK: - Display layer

/// The display path, which is the one that matters: `AVSampleBufferDisplayLayer` takes **compressed**
/// sample buffers in decode order and schedules them by presentation timestamp itself.
///
/// So the reordering the plan expected to have to write is the layer's job, not this package's, and
/// the demuxer's stored order is already the order to enqueue in.
@MainActor
@Suite(.tags(.file), .serialized)
struct MatroskaDisplayLayerTests {
    private let mkv = TestBundleResources.shared.sample_mkv

    /// Accepting every frame without failing is what says the format description, the timing and
    /// the sync attachments are all shaped the way the renderer expects — a wrong `avcC`, a missing
    /// keyframe marker or a bad timescale puts the layer into `.failed` with an error.
    @Test func acceptsEveryFrameOfTheFile() throws {
        let reader = try MatroskaFrameReader(url: mkv)
        let track = try #require(reader.file.videoTrack)
        let formatDescription = try track.makeFormatDescription()

        let layer = AVSampleBufferDisplayLayer()

        var enqueued = 0

        while let frame = try reader.nextFrame() {
            guard frame.trackNumber == track.number, frame.data.isEmpty == false else { continue }

            layer.enqueue(try frame.makeSampleBuffer(formatDescription: formatDescription))
            enqueued += 1
        }

        #expect(enqueued == 60)
        #expect(layer.error == nil)
        #expect(layer.status != .failed)
    }

    /// A WebM whose codec this machine cannot decode must still be *accepted* by the layer — the
    /// container work and the format description are sound either way, and only decode is missing.
    /// Keeps a VP9 failure from being read as a demuxer bug.
    @Test func acceptsWebMFramesRegardlessOfDecodeSupport() throws {
        let reader = try MatroskaFrameReader(url: TestBundleResources.shared.sample_webm)
        let track = try #require(reader.file.videoTrack)
        let formatDescription = try track.makeFormatDescription()

        let layer = AVSampleBufferDisplayLayer()

        while let frame = try reader.nextFrame() {
            guard frame.trackNumber == track.number, frame.data.isEmpty == false else { continue }
            layer.enqueue(try frame.makeSampleBuffer(formatDescription: formatDescription))
        }

        #expect(layer.error == nil)
    }
}

/// The decode handler runs on VideoToolbox's threads, so collection crosses a boundary the compiler
/// cannot see is serialized by the wait at the end.
private final class TimestampCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TimeInterval] = []

    func append(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var timestamps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
