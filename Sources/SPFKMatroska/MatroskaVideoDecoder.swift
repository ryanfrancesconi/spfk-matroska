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

    /// Pictures at each of `timestamps`, for a filmstrip.
    ///
    /// The counterpart to `SPFKVideo/VideoFrameExtractor/frames(from:at:maximumSize:)`, which needs
    /// an asset AVFoundation can open. One decoder is opened for the whole set rather than one per
    /// timestamp, because opening costs a header parse each time and a filmstrip asks for hundreds.
    ///
    /// **Timestamps are sorted ascending and walked in that order**, which is what makes a file with
    /// no `Cues` work at all: seeking fails there, so the walk simply keeps decoding forward to the
    /// next target — one pass over the file instead of one scan per frame. An indexed file seeks
    /// and only decodes the GOP it lands in.
    ///
    /// Each picture is scaled on the way out, so a feature-length filmstrip holds hundreds of
    /// thumbnails rather than hundreds of full-size frames. That is the difference between a few
    /// megabytes and a few gigabytes.
    ///
    /// Synchronous and not cheap. Call it off the main actor.
    ///
    /// - Parameter maximumSize: bounds the output, preserving aspect ratio. A zero or negative
    ///   width or height is treated as unconstrained on that axis, matching
    ///   `AVAssetImageGenerator.maximumSize`.
    /// - Parameter onImage: called with each picture as it is decoded, in ascending timestamp order,
    ///   on whatever thread this runs on. **A filmstrip over a feature-length file takes long enough
    ///   that a caller drawing only the returned dictionary looks hung** — this exists so the strip
    ///   can fill in as the scan proceeds, which is a better progress indicator than a bar because
    ///   it is the actual result appearing.
    /// - Returns: a picture per timestamp that yielded one. Timestamps past the end are absent
    ///   rather than an error — a container states a segment length, not a track length.
    public static func images(
        url: URL,
        at timestamps: [TimeInterval],
        maximumSize: CGSize? = nil,
        onImage: ((TimeInterval, CGImage) -> Void)? = nil
    ) throws -> [TimeInterval: CGImage] {
        guard timestamps.isEmpty == false else { return [:] }

        let decoder = try MatroskaVideoDecoder(url: url)

        var images: [TimeInterval: CGImage] = [:]
        var canSeek = true

        for timestamp in timestamps.sorted() {
            if canSeek {
                do {
                    try decoder.seek(to: timestamp)
                } catch MatroskaError.noSeekIndex {
                    // Asked once. Every subsequent seek would fail the same way, and the walk below
                    // already reaches an ascending target without one.
                    canSeek = false
                }
            }

            guard let frame = try decoder.frame(atOrAfter: timestamp) else { break }
            guard let image = frame.cgImage else { continue }

            let scaled = maximumSize.flatMap { image.scaled(within: $0) } ?? image

            images[timestamp] = scaled
            onImage?(timestamp, scaled)
        }

        return images
    }

    /// The first decoded picture whose presentation time reaches `timestamp`.
    ///
    /// After a successful seek this is the next picture; without one it decodes forward until the
    /// target is reached, which is why the caller must ask in ascending order.
    private func frame(atOrAfter timestamp: TimeInterval) throws -> MatroskaVideoFrame? {
        while let frame = try nextImage() {
            if frame.timestamp >= timestamp {
                return frame
            }
        }

        return nil
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

// MARK: -

extension CGImage {
    /// A copy scaled to fit inside `size`, preserving aspect ratio and never enlarging.
    ///
    /// Local to this package rather than `SPFKUtils.CGImage.scaled(to:)`, which takes an exact size
    /// and which `spfk-matroska` cannot reach — it depends on `spfk-base` and `spfk-video` only, and
    /// a dependency edge for one downscale is the more expensive of the two options.
    ///
    /// A zero or negative extent leaves that axis unconstrained, matching
    /// `AVAssetImageGenerator.maximumSize` so a filmstrip built from either source is bounded the
    /// same way.
    func scaled(within size: CGSize) -> CGImage? {
        let widthRatio = size.width > 0 ? size.width / CGFloat(width) : .greatestFiniteMagnitude
        let heightRatio = size.height > 0 ? size.height / CGFloat(height) : .greatestFiniteMagnitude

        let ratio = min(widthRatio, heightRatio)

        guard ratio < 1 else { return self }

        let scaledWidth = Int((CGFloat(width) * ratio).rounded())
        let scaledHeight = Int((CGFloat(height) * ratio).rounded())

        guard scaledWidth > 0, scaledHeight > 0, let colorSpace else { return nil }

        guard let context = CGContext(
            data: nil,
            width: scaledWidth,
            height: scaledHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))

        return context.makeImage()
    }
}
