// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreMedia
import CoreVideo
import Foundation
import SPFKBase
import SPFKVideo
import VideoToolbox

/// One decoded picture.
///
/// Deliberately not `Sendable`: `CVPixelBuffer` is a mutable image buffer with no concurrency
/// guarantees, and claiming otherwise would let the compiler bless handing one across actors.
public struct MatroskaVideoFrame {
    public let image: CVPixelBuffer

    /// Presentation time in seconds from the start of the segment.
    public let timestamp: TimeInterval

    public let isKeyframe: Bool

    /// The picture as a `CGImage`, or `nil` if the pixel format cannot be converted.
    public var cgImage: CGImage? {
        var result: CGImage?
        VTCreateCGImageFromCVPixelBuffer(image, options: nil, imageOut: &result)
        return result
    }
}

/// Decodes a Matroska or WebM file's video track to pictures, through VideoToolbox.
///
/// **The decoder is Apple's.** This package demuxes and describes; the codecs are pool-licensed and
/// macOS already ships decoders for them.
///
/// Frames come back in **decode order, not presentation order** — a stream with B-frames stores
/// them reordered and each decoded picture carries its own presentation timestamp. Anything showing
/// them in sequence has to order by ``MatroskaVideoFrame/timestamp``; anything wanting a single
/// picture does not care.
public final class MatroskaVideoDecoder {
    public let url: URL
    public let track: MatroskaTrack
    public let formatDescription: CMVideoFormatDescription

    private let reader: MatroskaFrameReader
    private let session: VTDecompressionSession

    /// Opens `url` and prepares to decode its first video track.
    ///
    /// - Throws: ``MatroskaError``, ``MatroskaSampleBufferError``, or
    ///   ``MatroskaVideoDecoderError``.
    public init(url: URL) throws {
        self.url = url

        reader = try MatroskaFrameReader(url: url)

        guard let track = reader.file.videoTrack else {
            throw MatroskaVideoDecoderError.noVideoTrack(url)
        }

        self.track = track
        formatDescription = try track.makeFormatDescription()

        var session: VTDecompressionSession?

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw MatroskaVideoDecoderError.decoderUnavailable(track.codecID, status: status)
        }

        self.session = session
    }

    deinit {
        VTDecompressionSessionInvalidate(session)
    }

    /// Decodes the next picture, or `nil` at the end of the track.
    ///
    /// Frames that decode to nothing — a stream can legitimately contain them — are skipped rather
    /// than returned as a gap, so a caller always gets a picture or the end.
    public func nextImage() throws -> MatroskaVideoFrame? {
        while let frame = try nextVideoFrame() {
            let sampleBuffer = try frame.makeSampleBuffer(formatDescription: formatDescription)

            let result = DecodeResult()

            // No `_EnableAsynchronousDecompression`, so VideoToolbox runs the handler before
            // returning and there is nothing to wait on. Deliberate: the caller pulls one frame at
            // a time, and reordering buys nothing when each picture carries its own timestamp.
            let status = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [],
                infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                result.status = status
                result.imageBuffer = imageBuffer
            }

            guard status == noErr, result.status == noErr else {
                throw MatroskaVideoDecoderError.decodeFailed(url, status: result.status == noErr ? status : result.status)
            }

            guard let image = result.imageBuffer else {
                continue
            }

            return MatroskaVideoFrame(image: image, timestamp: frame.timestamp, isKeyframe: frame.isKeyframe)
        }

        return nil
    }

    /// The first picture in the file — the cheapest thing to show for a container nothing else can
    /// open, and the one frame reachable without a seek index.
    public func firstImage() throws -> MatroskaVideoFrame? {
        try nextImage()
    }

    /// The first picture as a `CGImage`, for a still preview.
    ///
    /// Convenience for the common case: a caller that wants one picture out of a file AVFoundation
    /// will not open, without setting up a decode loop. Opening, decoding and closing costs the
    /// front of the file rather than a scan, because the first frame is in the first cluster.
    public static func firstCGImage(url: URL) throws -> CGImage? {
        let decoder = try MatroskaVideoDecoder(url: url)

        guard let frame = try decoder.firstImage() else {
            return nil
        }

        return frame.cgImage
    }

    /// The poster frame for a Matroska file, or `nil` for anything this package cannot open.
    ///
    /// Samples ``SPFKVideo/VideoFrameExtractor/posterFrameTimestamp(duration:)`` — the same rule
    /// AVFoundation-openable formats get — so a Matroska thumbnail and an MP4 one sitting next to
    /// each other in a list come from the same place in their respective files. A file reporting no
    /// duration falls back to the first frame, which is all there is to offer.
    ///
    /// **Not throwing, and silent about a non-Matroska file.** Every caller reaches this as a
    /// fallback after something else declined the URL, so "this is an MP4" is the expected answer
    /// rather than an error worth reporting. A file that *is* Matroska and still fails is logged.
    /// Matching ``MatroskaFile/videoTrackProperties(for:)``, which resolves the same way.
    ///
    /// The container is identified by reading its EBML header rather than by extension, so there is
    /// no list here to fall out of step with the ones in `AudioFileType`.
    ///
    /// Synchronous and not cheap — a seek plus one GOP. Call it off the main actor.
    public static func posterCGImage(url: URL) -> CGImage? {
        do {
            let duration = try MatroskaFile(url: url).duration ?? 0
            let timestamp = VideoFrameExtractor.posterFrameTimestamp(duration: duration)

            guard timestamp > 0 else {
                return try firstCGImage(url: url)
            }

            return try cgImage(url: url, at: timestamp)

        } catch MatroskaError.notMatroska {
            return nil

        } catch {
            Log.error("Failed to read a Matroska poster frame for \(url.lastPathComponent)", error)
            return nil
        }
    }

    /// Repositions to the keyframe at or before `timestamp` and clears the decoder's state.
    ///
    /// - Throws: ``MatroskaError/noSeekIndex(_:)`` when the file carries no index.
    public func seek(to timestamp: TimeInterval) throws {
        try reader.seek(to: timestamp, trackNumber: track.number)

        // The session holds reference frames from wherever it was; a new GOP must not be decoded
        // against them.
        VTDecompressionSessionFinishDelayedFrames(session)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
    }

    /// One picture from `timestamp`, for a still preview.
    ///
    /// Seeks first, so this costs an index lookup and one GOP rather than decoding everything up to
    /// that point. Falls back to the first frame for a file with no index, because a picture from
    /// the wrong place still beats a black rectangle.
    public static func cgImage(url: URL, at timestamp: TimeInterval) throws -> CGImage? {
        let decoder = try MatroskaVideoDecoder(url: url)

        do {
            try decoder.seek(to: timestamp)
        } catch MatroskaError.noSeekIndex {
            // Keep going from the start rather than failing the preview outright. Logged because
            // the fallback is otherwise indistinguishable from a working seek: the caller gets a
            // picture either way, and the picture from frame zero is black for most films.
            Log.debug("No usable seek index in \(url.lastPathComponent); poster falls back to the first frame")
        }

        return try decoder.nextImage()?.cgImage
    }

    /// Skips the interleaved audio and subtitle frames the demuxer hands back alongside video.
    private func nextVideoFrame() throws -> MatroskaFrame? {
        while let frame = try reader.nextFrame() {
            if frame.trackNumber == track.number, frame.data.isEmpty == false {
                return frame
            }
        }

        return nil
    }

    /// The handler runs on VideoToolbox's side of the call, so the result crosses a boundary the
    /// compiler cannot see is synchronous.
    private final class DecodeResult: @unchecked Sendable {
        var status: OSStatus = noErr
        var imageBuffer: CVImageBuffer?
    }
}

// MARK: - Errors

public enum MatroskaVideoDecoderError: Error, Equatable, Sendable {
    case noVideoTrack(URL)
    case decoderUnavailable(String, status: OSStatus)
    case decodeFailed(URL, status: OSStatus)
}

extension MatroskaVideoDecoderError: LocalizedError {
    /// Plain English rather than a localized string, matching the other error types here — the
    /// user-facing wording lives in the UI layer, where the catalogs are.
    public var errorDescription: String? {
        switch self {
        case let .noVideoTrack(url):
            "\(url.lastPathComponent) has no video track"

        case let .decoderUnavailable(codecID, status):
            "No system decoder is available for \(codecID) (\(status))"

        case let .decodeFailed(url, status):
            "Failed to decode video in \(url.lastPathComponent) (\(status))"
        }
    }
}

