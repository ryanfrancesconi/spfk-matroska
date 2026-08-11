// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreMedia
import Foundation
import SPFKBase

/// Sample buffers in transit from the thread that read them to the one that will enqueue them.
///
/// `CMSampleBuffer` is not `Sendable` on macOS. The unchecked conformance is a transfer, not a
/// claim of thread safety: the reader keeps no reference once it has handed a buffer back.
public struct MatroskaSampleBatch: @unchecked Sendable {
    public let video: [CMSampleBuffer]
    public let audio: [CMSampleBuffer]

    /// Whether the walk reached the end of the file.
    public let isEndOfFile: Bool

    public var isEmpty: Bool { video.isEmpty && audio.isEmpty }
}

/// A file's video and audio tracks as `CMSampleBuffer`s, in the order they are stored.
///
/// Stored order is decode order and is what a renderer wants, so nothing here reorders. Video
/// timestamps therefore do not ascend for a stream with B-frames.
///
/// Both tracks come out of one walk, because the muxer already interleaved them — a second reader
/// would mean a second file handle and two positions to keep in step. Clusters are parsed as the
/// walk reaches them.
public final class MatroskaSampleBufferReader: @unchecked Sendable {
    public let url: URL

    public let videoTrack: MatroskaTrack
    public let videoFormatDescription: CMVideoFormatDescription

    /// `nil` when the file has no audio, or none this package can describe — neither is a failure,
    /// and the picture still plays.
    public let audioTrack: MatroskaTrack?
    public let audioFormatDescription: CMAudioFormatDescription?

    /// Every describable audio track, in stored order. A dual-audio film states two and the
    /// muxer's order is not a preference, so a caller offers the choice.
    public let availableAudioTracks: [MatroskaTrack]

    private let reader: MatroskaFrameReader

    /// Driven from a feed queue rather than the actor that built it, so access is serialized here.
    private let lock = NSLock()

    /// Opens `url` and prepares its first video track, and its first audio track if it has one.
    ///
    /// - Throws: ``MatroskaError``, ``MatroskaSampleBufferError``,
    ///   ``MatroskaVideoDecoderError/noVideoTrack(_:)``.
    /// - Parameter audioTrackNumber: which audio track to read. Defaults to the first stored, which
    ///   is the muxer's ordering rather than a choice.
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

            if case let .audio(parameters) = track.kind, parameters.sampleRate > 0 {
                audioSampleRate = Int32(parameters.sampleRate)
            } else {
                audioSampleRate = nil
            }
        } else {
            audioTrack = nil
            audioFormatDescription = nil
            audioSampleRate = nil
        }
    }

    /// Up to `count` frames from the file, split by track.
    ///
    /// `count` is frames read, not returned per track: the interleave decides the split. Frames
    /// from other tracks are skipped and still count, so a file full of them cannot spin.
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

    /// The rate the audio grid is counted in. `nil` for a track stating none, which then keeps the
    /// container's own timing.
    ///
    /// How long each packet is comes from ``MatroskaTrack/audioFrameCount(forPacket:)`` rather than
    /// being fixed here: Opus states its length per packet and can vary it within one stream.
    private let audioSampleRate: Int32?

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
    ///
    /// **Returning `nil` costs the audio entirely, rather than degrading it.** The container states
    /// no block duration, so a buffer built from its timing carries an invalid one, and
    /// `AVSampleBufferAudioRenderer` rejects every such buffer with
    /// `kCMSampleBufferError_SampleTimingInfoInvalid` (-12740) while the picture plays on.
    private func audioTiming(for frame: MatroskaFrame) -> CMSampleTimingInfo? {
        guard let sampleRate = audioSampleRate,
              let audioTrack,
              let framesInPacket = audioTrack.audioFrameCount(forPacket: frame.data)
        else {
            return nil
        }

        let grid = (framesPerPacket: Int64(framesInPacket), sampleRate: sampleRate)
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
