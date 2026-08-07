// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreGraphics
import Foundation
import SPFKBase
import SPFKVideo

public extension MatroskaVideoDecoder {
    /// Stills at each of `timestamps`, from one open of the file.
    ///
    /// Opening per timestamp would cost a header parse and a decoder for every thumbnail on a
    /// filmstrip; this seeks within a single decoder instead. Timestamps are visited in ascending
    /// order for the same reason — a seek forward within a loaded file is cheap, a seek backward
    /// discards the decoder's reference frames.
    ///
    /// Keyed by the *requested* timestamp rather than the frame's own, so an evenly spaced request
    /// comes back evenly spaced and a filmstrip stays visually uniform. A timestamp that yields no
    /// picture is absent rather than zero — callers already draw a gap for a missing frame.
    ///
    /// A file with **no index still fills the whole strip**, by decoding on to each target rather
    /// than giving up: seeking is what is unavailable, not reading. That is one pass over the file
    /// for the set instead of one scan per frame, and it is why the ascending order above is a
    /// requirement rather than an optimization. An earlier version stopped at the first such
    /// failure and left the rest of the strip blank — which is most of the `.mkv` files that turn up.
    ///
    /// - Parameter maximumSize: longest-edge bound, preserving aspect. `nil` leaves frames at their
    ///   native size, which for a 4K film is not what a filmstrip wants.
    /// - Parameter onImage: called with each picture as it is decoded, in ascending order, on
    ///   whatever thread this runs on. **A feature-length file takes long enough that a caller
    ///   drawing only the returned dictionary looks hung** — this lets the strip fill in as the scan
    ///   proceeds, which beats a progress bar because it is the actual result appearing.
    static func cgImages(
        url: URL,
        at timestamps: [TimeInterval],
        maximumSize: CGFloat? = nil,
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
                    // Asked once. Every later seek fails the same way and the walk below reaches an
                    // ascending target without one.
                    canSeek = false
                }
            }

            guard let frame = try decoder.frame(atOrAfter: timestamp) else { break }
            guard let image = frame.cgImage else { continue }

            let scaled = maximumSize.flatMap { image.scaledPreservingAspect(to: $0) } ?? image

            images[timestamp] = scaled
            onImage?(timestamp, scaled)
        }

        return images
    }

    /// The first decoded picture whose presentation time reaches `timestamp`.
    ///
    /// After a successful seek that is the next picture; without one it decodes forward until the
    /// target is reached, which is why callers must ask in ascending order.
    private func frame(atOrAfter timestamp: TimeInterval) throws -> MatroskaVideoFrame? {
        while let frame = try nextImage() {
            if frame.timestamp >= timestamp {
                return frame
            }
        }

        return nil
    }
}

public extension VideoFrameExtractor {
    /// Stills from any container, including the ones AVFoundation will not open.
    ///
    /// The frame-extraction counterpart to `VideoTrackReader.readAnyContainer(from:)`, and it forks
    /// the same way: AVFoundation first, the demuxer only for a file it declined. So no existing
    /// format changes path, and a caller does not ask which one answered.
    ///
    /// - Returns: images keyed by requested timestamp. Empty when nothing can read the file, which
    ///   callers already treat as "draw the strip blank".
    /// - Parameter onImage: called with each picture as it is decoded, for a caller that wants to
    ///   draw the strip as it fills. **Only the demuxer path reports incrementally** —
    ///   AVFoundation's generator returns the set at once — so a caller must still draw the returned
    ///   dictionary rather than relying on this alone. That asymmetry is acceptable because the
    ///   demuxer path is the slow one: it walks the file, where AVFoundation seeks.
    static func framesForAnyContainer(
        from url: URL,
        at timestamps: [TimeInterval],
        maximumSize: CGSize,
        onImage: (@Sendable (TimeInterval, CGImage) -> Void)? = nil
    ) async -> [TimeInterval: CGImage] {
        if let frames = try? await frames(from: url, at: timestamps, maximumSize: maximumSize),
           frames.isEmpty == false {
            return frames
        }

        let longestEdge = max(maximumSize.width, maximumSize.height)

        do {
            return try MatroskaVideoDecoder.cgImages(
                url: url,
                at: timestamps,
                maximumSize: longestEdge > 0 ? longestEdge : nil,
                onImage: onImage
            )
        } catch MatroskaError.notMatroska {
            return [:]
        } catch {
            Log.error("Failed to extract Matroska filmstrip frames for \(url.lastPathComponent)", error)
            return [:]
        }
    }
}

extension CGImage {
    /// Scaled so its longest edge is `maximumSize`, or itself when already smaller.
    ///
    /// Local rather than `SPFKUtils`'s equivalent, which takes an exact size and which this package
    /// does not depend on — the aspect arithmetic is the part worth not duplicating at call sites.
    func scaledPreservingAspect(to maximumSize: CGFloat) -> CGImage? {
        let longestEdge = CGFloat(max(width, height))

        guard longestEdge > maximumSize, longestEdge > 0 else { return self }

        let scale = maximumSize / longestEdge
        let scaledWidth = Int((CGFloat(width) * scale).rounded())
        let scaledHeight = Int((CGFloat(height) * scale).rounded())

        guard let colorSpace,
              let context = CGContext(
                  data: nil,
                  width: scaledWidth,
                  height: scaledHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            return self
        }

        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))

        return context.makeImage()
    }
}
