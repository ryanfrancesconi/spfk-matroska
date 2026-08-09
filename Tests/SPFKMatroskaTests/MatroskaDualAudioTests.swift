// Copyright Ryan Francesconi. All Rights Reserved.

import Foundation
import SPFKTesting
import SPFKVideo
import Testing

@testable import SPFKMatroska

/// A file with more than one audio track, which is what audio track selection is built against.
@Suite(.tags(.file), .serialized)
final class MatroskaDualAudioTests {
    let url = TestBundleResources.shared.sample_dualaudio_mkv

    /// `audioTrack` answers "the first one", which is the muxer's ordering rather than a choice —
    /// so it cannot be the thing a selector reads.
    @Test func readsBothAudioTracksAndNamesThem() throws {
        let file = try MatroskaFile(url: url)

        let audio = file.tracks.filter { if case .audio = $0.kind { true } else { false } }

        #expect(audio.count == 2)
        #expect(audio.map(\.language) == ["eng", "jpn"])
        #expect(audio.map(\.name) == ["English", "Japanese"])
        #expect(audio.allSatisfy { $0.codecID == "A_AAC" })

        #expect(file.audioTrack?.language == "eng")
    }

    /// The subtitle track is why this is a `filter` rather than an index: it sits after both audio
    /// tracks, so a reader that counts positions instead of testing `kind` picks it up.
    @Test func describesTheNonAudioTracksSeparately() throws {
        let file = try MatroskaFile(url: url)

        #expect(file.videoTrack?.codecID == "V_MPEG4/ISO/AVC")
        #expect(file.tracks.contains { $0.kind == .subtitle })
    }

    /// Both tracks are describable, so a picker offers both rather than silently dropping one whose
    /// codec could not be mapped.
    @Test func offersBothTracksToASampleBufferReader() throws {
        let reader = try MatroskaSampleBufferReader(url: url)

        #expect(reader.availableAudioTracks.count == 2)
        #expect(reader.audioTrack?.language == "eng")
    }

    /// The parameter that already exists, exercised — opening for the second track selects it
    /// rather than falling back to the first.
    @Test func opensTheRequestedAudioTrack() throws {
        let file = try MatroskaFile(url: url)
        let japanese = try #require(file.tracks.first { $0.language == "jpn" })

        let reader = try MatroskaSampleBufferReader(url: url, audioTrackNumber: Int64(japanese.number))

        #expect(reader.audioTrack?.number == japanese.number)
        #expect(reader.audioTrack?.name == "Japanese")
    }

    /// A track number the file does not carry falls back to the first rather than throwing: a stale
    /// persisted selection should still play something.
    @Test func fallsBackWhenTheRequestedTrackIsAbsent() throws {
        let reader = try MatroskaSampleBufferReader(url: url, audioTrackNumber: 999)

        #expect(reader.audioTrack?.language == "eng")
    }

    // MARK: - Neutral description

    /// `TrackUID` is what a persisted selection is keyed on, so it has to actually arrive — a
    /// bridged field that was never assigned reads as a plausible 0 for every track.
    @Test func carriesADistinctTrackUIDPerTrack() throws {
        let file = try MatroskaFile(url: url)

        let uids = file.tracks.map(\.uid)

        #expect(uids.allSatisfy { $0 != 0 })
        #expect(Set(uids).count == file.tracks.count)
    }

    /// The picker's rows, from the container's own `Name`/`Language`.
    @Test func describesAudioTracksNeutrally() throws {
        let file = try MatroskaFile(url: url)

        let descriptions = file.audioTrackDescriptions

        #expect(descriptions.count == 2)
        #expect(descriptions.map(\.displayName) == ["English", "Japanese"])
        #expect(descriptions.allSatisfy { $0.channelCount == 1 })
        #expect(descriptions.allSatisfy { $0.sampleRate == 44100 })
    }

    /// The mapping back: a picker hands over an identifier and the reader is opened by number.
    @Test func resolvesANeutralIdentifierBackToItsTrack() throws {
        let file = try MatroskaFile(url: url)

        let japanese = try #require(file.audioTrackDescriptions.first { $0.language == "jpn" })
        let track = try #require(file.audioTrack(id: japanese.id))

        #expect(track.name == "Japanese")

        let reader = try MatroskaSampleBufferReader(url: url, audioTrackNumber: Int64(track.number))
        #expect(reader.audioTrack?.name == "Japanese")
    }

    /// A selection that outlived the file it was made against resolves to nothing rather than to
    /// whichever track happens to sit at that position.
    @Test func resolvesAnUnknownIdentifierToNothing() throws {
        let file = try MatroskaFile(url: url)

        #expect(file.audioTrack(id: AudioTrackDescription.ID(rawValue: 999_999)) == nil)
    }

    /// The video and subtitle tracks are not offered as audio, which a `compactMap` over every
    /// track would do if it keyed on anything but `kind`.
    @Test func describesOnlyTheAudioTracks() throws {
        let file = try MatroskaFile(url: url)

        #expect(file.tracks.count > file.audioTrackDescriptions.count)
        #expect(file.videoTrack?.audioTrackDescription == nil)
    }
}
