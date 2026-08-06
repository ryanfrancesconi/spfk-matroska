// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKMatroskaC

/// A Matroska or WebM file's headers: everything readable without walking clusters.
///
/// This reads the front of the file — the EBML header and the segment's `Info` and `Tracks`
/// elements — and stops at the first cluster. Frame data is not touched, so constructing one of
/// these is cheap regardless of how long the file is.
public struct MatroskaFile: Hashable, Sendable {
    /// The EBML `DocType` the muxer declared. WebM is a Matroska profile and parses identically;
    /// this only records which name the file uses.
    public enum DocType: Hashable, Sendable {
        case matroska
        case webm
        case other(String)

        init(_ rawValue: String) {
            self = switch rawValue {
            case "matroska": .matroska
            case "webm": .webm
            default: .other(rawValue)
            }
        }
    }

    public let url: URL
    public let docType: DocType

    /// The segment `Title`. Distinct from the `title` tag TagLib reads out of the `Tags` element —
    /// a file can carry both, and they can disagree.
    public let title: String?

    public let muxingApp: String?
    public let writingApp: String?

    /// Nanoseconds per timecode unit — 1,000,000 (millisecond resolution) in practice. Every raw
    /// timecode in the file is expressed in these units.
    public let timecodeScale: Int64

    /// Total duration in seconds, or `nil` when the file states none. Live and streamed captures
    /// legitimately omit it, so `nil` means unknown rather than empty.
    public let duration: TimeInterval?

    public let tracks: [MatroskaTrack]

    /// Reads the headers at `url`.
    ///
    /// - Throws: ``MatroskaError``.
    public init(url: URL) throws {
        let description: MKVSegmentDescription

        do {
            description = try MKVDemuxer.readSegmentDescription(at: url)
        } catch {
            throw MatroskaError.from(error, url: url)
        }

        self.init(url: url, description: description)
    }

    /// Wraps headers a caller already has, so opening a file for frames does not mean parsing its
    /// headers a second time to describe it.
    init(url: URL, description: MKVSegmentDescription) {
        self.url = url
        docType = DocType(description.docType)
        title = description.title
        muxingApp = description.muxingApp
        writingApp = description.writingApp
        timecodeScale = description.timecodeScale
        duration = description.durationNanoseconds > 0
            ? TimeInterval(description.durationNanoseconds) / 1_000_000_000
            : nil
        tracks = description.tracks.map(MatroskaTrack.init)
    }
}

// MARK: - Track lookup

extension MatroskaFile {
    /// The first video track, which is the one to display. Matroska allows several; no consumer
    /// here has a use for the others yet.
    public var videoTrack: MatroskaTrack? {
        tracks.first { if case .video = $0.kind { true } else { false } }
    }

    /// The first audio track, which is the one to play.
    public var audioTrack: MatroskaTrack? {
        tracks.first { if case .audio = $0.kind { true } else { false } }
    }

    /// The track carrying `number`, which blocks reference rather than an index.
    public func track(number: Int) -> MatroskaTrack? {
        tracks.first { $0.number == number }
    }
}
