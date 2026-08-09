// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKVideo

extension MatroskaTrack {
    /// This track described in the neutral terms a picker is written against, or `nil` for a track
    /// that is not audio.
    ///
    /// Keyed on ``uid`` rather than ``number``, so a selection outlives a remux. The reader is
    /// still opened by number — see ``MatroskaFile/audioTrack(id:)``, which is the mapping back.
    public var audioTrackDescription: AudioTrackDescription? {
        guard case let .audio(parameters) = kind else { return nil }

        return AudioTrackDescription(
            id: AudioTrackDescription.ID(rawValue: uid),
            name: name,
            language: language,
            codec: codecName ?? codecID,
            channelCount: parameters.channelCount,
            sampleRate: parameters.sampleRate
        )
    }
}

extension MatroskaFile {
    /// Every audio track, described neutrally.
    ///
    /// Includes tracks whose codec cannot be decoded here — listing is a question about the file,
    /// and a caller that can only offer playable tracks filters for itself. `MatroskaSampleBufferReader`
    /// does exactly that, which is why its own list is the narrower one.
    public var audioTrackDescriptions: [AudioTrackDescription] {
        tracks.compactMap(\.audioTrackDescription)
    }

    /// The track a neutral identifier names, mapping `TrackUID` back to the track a reader is
    /// opened with. `nil` when the file no longer carries it — a persisted selection surviving the
    /// file being replaced.
    public func audioTrack(id: AudioTrackDescription.ID) -> MatroskaTrack? {
        tracks.first { track in
            guard case .audio = track.kind else { return false }
            return track.uid == id.rawValue
        }
    }
}
