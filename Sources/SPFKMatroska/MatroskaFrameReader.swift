// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKMatroskaC

/// Walks a Matroska or WebM file's frames in stored (muxed) order.
///
/// Clusters are parsed lazily as the walk reaches them, so opening a long file costs the front of
/// it and memory grows with what has been read rather than with the file's length.
///
/// Frames arrive interleaved across tracks exactly as the muxer wrote them, which is the order a
/// player wants: audio and video for the same instant sit next to each other, so playback needs
/// neither seeking nor buffering one track while scanning for the other.
///
/// Not thread-safe, and deliberately a class: it holds a position in the file, so sharing one
/// across concurrent readers would interleave their walks. Open one per walk.
public final class MatroskaFrameReader {
    private let reader: MKVFrameReader

    public let url: URL

    /// The file's headers, so reading frames does not mean opening the file twice.
    public let file: MatroskaFile

    /// Opens `url` and parses its headers.
    ///
    /// - Throws: ``MatroskaError``.
    public init(url: URL) throws {
        do {
            reader = try MKVFrameReader(url: url)
        } catch {
            throw MatroskaError.from(error, url: url)
        }

        self.url = url
        file = MatroskaFile(url: url, description: reader.segmentDescription)
    }

    /// The next frame, or `nil` at the end of the file.
    ///
    /// - Throws: ``MatroskaError`` if the walk stopped on a malformed cluster rather than reaching
    ///   the end. A clean end is `nil` and not an error.
    public func nextFrame() throws -> MatroskaFrame? {
        guard let frame = reader.nextFrame() else {
            if let failure = reader.failure {
                throw MatroskaError.from(failure, url: url)
            }

            return nil
        }

        return MatroskaFrame(frame)
    }
}

// MARK: - Sequence

extension MatroskaFrameReader {
    /// Every remaining frame for one track.
    ///
    /// **Reads the whole file and holds the result**, so this is for short files and tests. A
    /// player walks with ``nextFrame()`` and keeps the interleaving.
    public func allFrames(ofTrack trackNumber: Int? = nil) throws -> [MatroskaFrame] {
        var frames: [MatroskaFrame] = []

        while let frame = try nextFrame() {
            guard let trackNumber else {
                frames.append(frame)
                continue
            }

            if frame.trackNumber == trackNumber {
                frames.append(frame)
            }
        }

        return frames
    }
}
