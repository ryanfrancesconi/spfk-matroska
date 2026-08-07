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

    /// Every audio track in the file that this package can describe, in stored order.
    ///
    /// A dual-audio film states two — an original and a dub — and which one the muxer wrote first
    /// is not a preference. Listed so a caller can offer the choice; pass a track number to
    /// ``init(url:audioTrackNumber:)`` to take it.
    public let availableAudioTracks: [MatroskaTrack]

    private let reader: MatroskaFrameReader

    /// The reader is handed to a feed queue and driven from there, off whatever actor built it, so
    /// its own access is serialized here rather than by an isolation the type cannot express.
    private let lock = NSLock()

    /// Opens `url` and prepares its first video track, and its first audio track if it has one.
    ///
    /// - Throws: ``MatroskaError``, ``MatroskaSampleBufferError``,
    ///   ``MatroskaVideoDecoderError/noVideoTrack(_:)``.
    /// - Parameter audioTrackNumber: which audio track to read. Defaults to the file's first, which
    ///   is what a muxer's ordering happens to give and not a choice. Ignored when the file has no
    ///   such track.
    public init(url: URL, audioTrackNumber: Int64? = nil) throws {
        self.url = url

        reader = try MatroskaFrameReader(url: url)

        guard let videoTrack = reader.file.videoTrack else {
            throw MatroskaVideoDecoderError.noVideoTrack(url)
        }

        self.videoTrack = videoTrack
        videoFormatDescription = try videoTrack.makeFormatDescription()

        let describableAudioTracks = reader.file.tracks.filter {
            if case .audio = $0.kind { return (try? $0.makeAudioFormatDescription()) != nil }
            return false
        }

        availableAudioTracks = describableAudioTracks

        let requested = audioTrackNumber.flatMap { number in
            describableAudioTracks.first { $0.number == number }
        }

        if let track = requested ?? describableAudioTracks.first,
           let description = try? track.makeAudioFormatDescription() {
            audioTrack = track
            audioFormatDescription = description

            if case let .audio(parameters) = track.kind,
               let codec = MatroskaAudioCodec(rawValue: track.codecID),
               codec.framesPerPacket > 0, parameters.sampleRate > 0 {
                audioPacketGrid = (Int64(codec.framesPerPacket), Int32(parameters.sampleRate))
            } else {
                audioPacketGrid = nil
            }
        } else {
            audioTrack = nil
            audioFormatDescription = nil
            audioPacketGrid = nil
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
                audio.append(try frame.makeSampleBuffer(
                    formatDescription: audioFormatDescription,
                    timing: audioTiming(for: frame)
                ))
            }
        }

        return MatroskaSampleBatch(video: video, audio: audio, isEndOfFile: false)
    }

    // MARK: - Audio timing

    /// Packet grid the audio is placed on: how many frames each packet decodes to, and at what
    /// rate. `nil` for a codec whose packets are not a fixed length, which then keeps the
    /// container's own timing.
    private let audioPacketGrid: (framesPerPacket: Int64, sampleRate: Int32)?

    /// Where the current run of audio started, and how many frames into it we are.
    private var audioAnchor: CMTime?
    private var audioFrameOffset: Int64 = 0

    /// Timing for an audio packet, counted from the start of the run rather than read from the
    /// container.
    ///
    /// **Matroska quantizes block timestamps to the segment's `TimecodeScale`** — a millisecond in
    /// every file seen so far — and no compressed audio packet length divides that evenly. An AAC
    /// packet is 21.333 ms, so the stored times drift against the true grid and snap back at each
    /// block boundary; with lacing that is a discontinuity several times a second, and it is
    /// audible. Counting frames instead puts every packet exactly where it belongs.
    ///
    /// A jump larger than half a second is treated as a real discontinuity — a gap in the file, or
    /// a seek — and re-anchors rather than being smoothed away.
    private func audioTiming(for frame: MatroskaFrame) -> CMSampleTimingInfo? {
        guard let grid = audioPacketGrid else { return nil }

        let containerTime = CMTime(seconds: frame.timestamp, preferredTimescale: grid.sampleRate)

        let anchor: CMTime

        if let existing = audioAnchor {
            let expected = existing + CMTime(value: audioFrameOffset, timescale: grid.sampleRate)

            if abs((containerTime - expected).seconds) > 0.5 {
                audioAnchor = containerTime
                audioFrameOffset = 0
                anchor = containerTime
            } else {
                anchor = existing
            }
        } else {
            audioAnchor = containerTime
            audioFrameOffset = 0
            anchor = containerTime
        }

        let presentationTime = anchor + CMTime(value: audioFrameOffset, timescale: grid.sampleRate)
        audioFrameOffset += grid.framesPerPacket

        return CMSampleTimingInfo(
            duration: CMTime(value: grid.framesPerPacket, timescale: grid.sampleRate),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
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

        // The run restarts wherever the seek landed, so the frame count cannot carry across it.
        audioAnchor = nil
        audioFrameOffset = 0
    }

    /// The segment's duration, when it states one.
    public var duration: TimeInterval? {
        reader.file.duration
    }

    /// Whether this package can open `url` for playback.
    ///
    /// Answered by reading the file's headers rather than its extension, so it is true only when
    /// there is really a video track with a codec that can be described — a `.mkv` carrying DTS
    /// video, or a file misnamed `.mkv`, answers false rather than failing later.
    ///
    /// Costs the header parse, not a cluster walk, and a caller that gets `true` is about to open
    /// the file anyway.
    public static func canOpen(url: URL) -> Bool {
        (try? MatroskaSampleBufferReader(url: url)) != nil
    }
}
