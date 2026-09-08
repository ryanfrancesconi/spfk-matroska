// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKVideo

/// Extends `spfk-video`'s reader from here rather than beside it, because the dependency cannot run
/// the other way — `spfk-video` is a pure-Swift leaf with many dependents and must not pull C++ in
/// for a feature one of them uses.
public extension VideoTrackReader {
    /// ``VideoTrackReader/read(from:)`` with containers AVFoundation cannot open filled in.
    ///
    /// **This is what a caller asking "what are this file's video properties" wants**, and the
    /// plain AVFoundation read is what a caller specifically asking about AVFoundation wants.
    /// A `.mkv` has a video track whether or not the AV stack can see it, so the unqualified
    /// question has to be answered by whatever can answer it.
    ///
    /// Only the video track is filled. `isPlayable` stays as AVFoundation reported it — the file
    /// genuinely cannot be played yet, which is what the row's status indicator says — and
    /// `quickTimeUserData` stays nil, being a `moov`-atom concept with no Matroska equivalent.
    static func readAnyContainer(
        from url: URL
    ) async -> (
        videoTrack: VideoTrackProperties?,
        quickTimeUserData: QuickTimeUserData?,
        isPlayable: Bool,
        hasProtectedContent: Bool
    ) {
        let result = await read(from: url)

        guard result.videoTrack == nil else {
            return result
        }

        return (
            videoTrack: MatroskaFile.videoTrackProperties(for: url),
            quickTimeUserData: result.quickTimeUserData,
            isPlayable: result.isPlayable,
            hasProtectedContent: result.hasProtectedContent
        )
    }
}
