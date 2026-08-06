// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreMedia
import CoreVideo
import Foundation
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
