// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKBase
import SPFKVideo

/// Bridges a demuxed Matroska track into `spfk-video`'s shared shape, so a container AVFoundation
/// cannot open still reports resolution and frame rate through the same type as everything else.
///
/// The dependency runs this way deliberately — `spfk-video` is a pure-Swift leaf with many
/// dependents, and having it reach for the demuxer would make all of them build C++ for a feature
/// one of them uses.
public extension MatroskaTrack {
    /// The four-character code CoreMedia uses for this track's codec, mapped from the Matroska
    /// `CodecID`. `nil` for a codec with no CoreMedia equivalent.
    ///
    /// Matched to `VideoTrackReader`'s `codec`, which is a `CMFormatDescription` media subtype, so
    /// the same stream reports the same string whichever container carries it. Every value here is
    /// read from the `kCMVideoCodecType_*` constants rather than transcribed from a spec.
    var codecFourCC: String? {
        switch codecID {
        case "V_MPEG4/ISO/AVC": "avc1"
        case "V_MPEGH/ISO/HEVC": "hvc1"
        case "V_AV1": "av01"
        case "V_VP9": "vp09"
        case "V_MPEG4/ISO/ASP": "mp4v"
        default: nil
        }
    }

    /// Video-technical properties for a video track, or `nil` for any other kind.
    ///
    /// Two fields are deliberately left `nil` rather than filled with a plausible value:
    /// - `duration` — Matroska states a duration for the *segment*, not per track, and the two
    ///   differ whenever an audio track outruns the video. Container duration already reaches the
    ///   UI through TagLib.
    /// - `preciseFrameRate` — resolving a rate against `swift-timecode`'s standard-rate table
    ///   needs the exact rational frame duration, which means walking clusters.
    var videoTrackProperties: VideoTrackProperties? {
        guard case let .video(parameters) = kind else {
            return nil
        }

        return VideoTrackProperties(
            width: parameters.pixelWidth,
            height: parameters.pixelHeight,
            nominalFrameRate: frameRate.map(Float.init),
            codec: codecFourCC,
            pixelAspectRatio: pixelAspectRatio
        )
    }

    /// The width of one pixel over its height, or `nil` for square pixels.
    ///
    /// `nil` rather than 1.0 for the square case, matching `VideoTrackReader` — AVFoundation omits
    /// the `PixelAspectRatio` extension entirely for standard video, and a caller comparing the two
    /// paths should see the same absence.
    private var pixelAspectRatio: Double? {
        guard case let .video(parameters) = kind,
              parameters.displayUnit == .pixels,
              parameters.displayWidth > 0, parameters.displayHeight > 0,
              parameters.pixelWidth > 0, parameters.pixelHeight > 0
        else {
            return nil
        }

        let displayRatio = Double(parameters.displayWidth) / Double(parameters.displayHeight)
        let pixelRatio = Double(parameters.pixelWidth) / Double(parameters.pixelHeight)
        let ratio = displayRatio / pixelRatio

        return abs(ratio - 1) < 0.0001 ? nil : ratio
    }
}

public extension MatroskaFile {
    /// Video-technical properties for the track that would be displayed, or `nil` for a file with
    /// no video track.
    var videoTrackProperties: VideoTrackProperties? {
        videoTrack?.videoTrackProperties
    }

    /// Best-effort read for filling the gap AVFoundation leaves on a container it cannot open.
    ///
    /// Logs and returns `nil` instead of throwing, because every caller is completing an already
    /// best-effort parse where a failed read means one blank column rather than a failed import.
    /// One implementation on purpose — both products need exactly this, and the parse itself is
    /// the only part that is worth not writing twice.
    static func videoTrackProperties(for url: URL) -> VideoTrackProperties? {
        do {
            return try MatroskaFile(url: url).videoTrackProperties
        } catch {
            Log.error("Failed to read Matroska video track for \(url.lastPathComponent)", error)
            return nil
        }
    }
}
