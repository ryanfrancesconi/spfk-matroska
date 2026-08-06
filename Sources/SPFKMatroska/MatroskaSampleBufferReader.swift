// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreMedia
import Foundation
import SPFKBase

/// Sample buffers in transit from the thread that read them to the one that will enqueue them.
///
/// **`CMSampleBuffer` is not `Sendable` on macOS**, so a batch cannot cross an isolation boundary
/// without this. The unchecked conformance is a *transfer* rather than a claim of thread safety:
/// ``MatroskaSampleBufferReader`` keeps no reference to a buffer once it has handed one back, so
/// exactly one side holds each buffer at any moment.
public struct MatroskaSampleBatch: @unchecked Sendable {
    public let video: [CMSampleBuffer]
    public let audio: [CMSampleBuffer]

    /// Whether the walk reached the end of the file.
    public let isEndOfFile: Bool

    public var isEmpty: Bool { video.isEmpty && audio.isEmpty }
}

/// A file's video and audio tracks as `CMSampleBuffer`s, in the order they are stored.
///
/// **Stored order is decode order, and that is the order to enqueue in** — a renderer schedules by
/// presentation timestamp itself, so nothing here reorders anything. Worth stating because the
/// video timestamps deliberately do *not* ascend for a stream with B-frames, which looks like a bug
/// until you know it is the input a display layer wants.
///
/// **Both tracks come out of one walk.** The muxer already interleaved them — audio and video for
/// the same instant are adjacent — so reading them together is what keeps a player from seeking,
/// and a second reader over the same file would mean a second file handle and two positions to keep
/// in step.
///
/// Sequential and lazy: clusters are parsed as the walk reaches them, so a feature-length file
/// costs the part of it that has been played rather than all of it.
public final class MatroskaSampleBufferReader: @unchecked Sendable {
    public let url: URL

    public let videoTrack: MatroskaTrack
    public let videoFormatDescription: CMVideoFormatDescription

    /// The audio track, when the file has one this package can describe.
    ///
    /// **Nil is not a failure.** A file can legitimately have no audio, and a codec macOS cannot
    /// decode should still let the picture play — so an undescribable audio track is dropped here
    /// rather than failing the whole open.
    public let audioTrack: MatroskaTrack?
    public let audioFormatDescription: CMAudioFormatDescription?

    private let reader: MatroskaFrameReader

    /// The reader is handed to a feed queue and driven from there, off whatever actor built it, so
    /// its own access is serialized here rather than by an isolation the type cannot express.
    private let lock = NSLock()

    /// Opens `url` and prepares its first video track, and its first audio track if it has one.
    ///
    /// - Throws: ``MatroskaError``, ``MatroskaSampleBufferError``,
    ///   ``MatroskaVideoDecoderError/noVideoTrack(_:)``.
    public init(url: URL) throws {
        self.url = url

        reader = try MatroskaFrameReader(url: url)

        guard let videoTrack = reader.file.videoTrack else {
            throw MatroskaVideoDecoderError.noVideoTrack(url)
        }

        self.videoTrack = videoTrack
        videoFormatDescription = try videoTrack.makeFormatDescription()

        if let track = reader.file.audioTrack,
           let description = try? track.makeAudioFormatDescription() {
            audioTrack = track
            audioFormatDescription = description
        } else {
            audioTrack = nil
            audioFormatDescription = nil
        }
    }

    /// Up to `count` frames from the file, split by track.
    ///
    /// `count` is frames read, not frames returned per track — the walk covers the file once and
    /// the interleave decides the split, which is what keeps the two tracks aligned. A caller feeds
    /// whichever renderer wants more and lets the other's buffer absorb the difference.
    ///
    /// Frames from tracks that are neither the video nor the described audio track — subtitles, a
    /// second audio track — are skipped and still count against `count`, so a file full of them
    /// cannot spin.
    ///
    /// - Throws: ``MatroskaError``, ``MatroskaSampleBufferError``.
    public func next(upTo count: Int) throws -> MatroskaSampleBatch {
        lock.lock()
        defer { lock.unlock() }

        var video: [CMSampleBuffer] = []
        var audio: [CMSampleBuffer] = []
        var read = 0

        while read < count {
            guard let frame = try reader.nextFrame() else {
                return MatroskaSampleBatch(video: video, audio: audio, isEndOfFile: true)
            }

            read += 1

            guard frame.data.isEmpty == false else { continue }

            if frame.trackNumber == videoTrack.number {
                video.append(try frame.makeSampleBuffer(formatDescription: videoFormatDescription))

            } else if let audioTrack, let audioFormatDescription,
                      frame.trackNumber == audioTrack.number {
                audio.append(try frame.makeSampleBuffer(formatDescription: audioFormatDescription))
            }
        }

        return MatroskaSampleBatch(video: video, audio: audio, isEndOfFile: false)
    }

    /// Repositions the walk to the keyframe at or before `timestamp` on the video track.
    ///
    /// Audio resumes from wherever that lands, which is what a player wants: the picture cannot
    /// start mid-GOP, and audio can start anywhere.
    ///
    /// - Throws: ``MatroskaError/noSeekIndex(_:)`` when the file carries no usable index.
    public func seek(to timestamp: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }

        try reader.seek(to: timestamp, trackNumber: videoTrack.number)
    }

    /// The segment's duration, when it states one.
    public var duration: TimeInterval? {
        reader.file.duration
    }
}
