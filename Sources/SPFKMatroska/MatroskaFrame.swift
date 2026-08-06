// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKMatroskaC

/// One compressed frame, still encoded — this package demuxes and never decodes.
public struct MatroskaFrame: Hashable, Sendable {
    /// The `TrackNumber` this frame belongs to, matching ``MatroskaTrack/number``.
    public let trackNumber: Int

    /// The compressed payload, exactly as stored.
    public let data: Data

    /// Presentation time in seconds from the start of the segment.
    ///
    /// Matroska stores presentation time and has no container-level decode timestamp — a decoder
    /// reorders from the codec's own information. So in a stream with B-frames these are **not**
    /// monotonic in stored order, which is correct rather than a parse error.
    public let timestamp: TimeInterval

    /// How long the frame is shown, from the track's `DefaultDuration`, or `nil` when the file
    /// states none.
    public let duration: TimeInterval?

    /// Whether the frame decodes without reference to another.
    public let isKeyframe: Bool
}

// MARK: - Bridging

extension MatroskaFrame {
    init(_ frame: MKVFrame) {
        trackNumber = Int(frame.trackNumber)
        data = frame.data
        timestamp = TimeInterval(frame.timestampNanoseconds) / 1_000_000_000
        duration = frame.durationNanoseconds > 0
            ? TimeInterval(frame.durationNanoseconds) / 1_000_000_000
            : nil
        isKeyframe = frame.isKeyframe
    }
}
