// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKVideo

extension AudioTrackReader {
    /// Every audio track of `url`, whichever container it is in.
    ///
    /// The counterpart to `VideoTrackReader.readAnyContainer(from:)` and answered the same way: a
    /// `.mkv` has audio tracks whether or not the AV stack can see them, so the unqualified question
    /// goes to whatever can answer it.
    ///
    /// The AVFoundation read is tried first and its answer kept when it finds anything, so a
    /// container both can read is described by one path rather than two that could disagree.
    public static func readAnyContainer(from url: URL) async -> [AudioTrackDescription] {
        let tracks = await read(from: url)

        guard tracks.isEmpty else {
            return tracks
        }

        return (try? MatroskaFile(url: url))?.audioTrackDescriptions ?? []
    }
}
