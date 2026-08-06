// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKMatroskaC

/// Errors thrown while reading a Matroska or WebM container.
public enum MatroskaError: Error, Equatable, Sendable {
    /// The file could not be opened for reading.
    case unreadableFile(URL)

    /// No valid EBML header — the file is not Matroska or WebM at all.
    case notMatroska(URL)

    /// An EBML header is present but the segment headers are malformed.
    case malformedSegment(URL)

    /// Headers parsed, but the file declares no tracks.
    case noTracks(URL)
}

// MARK: - Bridging

extension MatroskaError {
    /// Recovers the typed case from the `NSError` the ObjC++ layer produces.
    ///
    /// An unrecognized code falls back to ``malformedSegment`` rather than trapping: a parser that
    /// grows a failure mode should surface as a read failure, not a crash.
    static func from(_ error: any Error, url: URL) -> MatroskaError {
        switch (error as NSError).code {
        case MKVError.unreadableFile.rawValue: .unreadableFile(url)
        case MKVError.notMatroska.rawValue: .notMatroska(url)
        case MKVError.noTracks.rawValue: .noTracks(url)
        default: .malformedSegment(url)
        }
    }
}

// MARK: - LocalizedError

extension MatroskaError: LocalizedError {
    /// Deliberately plain English rather than a localized string, matching `VideoEditError` — the
    /// user-facing wording lives in the UI layer, which is where the catalogs are.
    public var errorDescription: String? {
        switch self {
        case let .unreadableFile(url):
            "Could not open \(url.lastPathComponent)"

        case let .notMatroska(url):
            "\(url.lastPathComponent) is not a Matroska or WebM file"

        case let .malformedSegment(url):
            "\(url.lastPathComponent) has malformed Matroska headers"

        case let .noTracks(url):
            "\(url.lastPathComponent) contains no tracks"
        }
    }
}
