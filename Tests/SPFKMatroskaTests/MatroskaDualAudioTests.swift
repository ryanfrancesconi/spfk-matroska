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

    // MARK: - Language

    /// **A file that states no `Language` means English**, which is the element's declared default —
    /// so a muxer writes it only for everything else. libwebm applies no default, which made an
    /// English track the one track with no language at all, and its menu row the only one without a
    /// language beside it.
    ///
    /// The element is removed here rather than shipped as a fixture, because no muxer to hand
    /// produces one: ffmpeg writes `und` explicitly (which `sample.mkv` carries and this test
    /// starts from) where mkvmerge omits the element. Replaced by `Void` padding of the same
    /// length, so every offset in the file is unmoved — the same technique
    /// `sample-nested-seekhead.mkv` was built with.
    @Test func appliesTheSpecDefaultLanguageWhenTheFileStatesNone() throws {
        #expect(try MatroskaFile(url: TestBundleResources.shared.sample_mkv).audioTrack?.language == "und")

        let patched = FileManager.default.temporaryDirectory
            .appendingPathComponent("spfk-no-language-\(UUID().uuidString).mkv")

        defer { try? FileManager.default.removeItem(at: patched) }

        var data = try Data(contentsOf: TestBundleResources.shared.sample_mkv)

        // `Language` (0x22B59C), a 1-byte size of 3, then "und".
        let element = Data([0x22, 0xB5, 0x9C, 0x83]) + Data("und".utf8)

        // `Void` (0xEC) with a 5-byte payload fills the same seven bytes.
        let void = Data([0xEC, 0x85, 0x00, 0x00, 0x00, 0x00, 0x00])

        var replaced = 0

        while let range = data.range(of: element) {
            data.replaceSubrange(range, with: void)
            replaced += 1
        }

        #expect(replaced > 0, "the fixture no longer states a language to remove")

        try data.write(to: patched)

        let audio = try #require(try MatroskaFile(url: patched).audioTrack)

        #expect(audio.language == "eng")
        #expect(audio.audioTrackDescription?.localizedLanguage == "English")
    }

    /// A stated language still wins — the default fills a gap rather than overwriting.
    @Test func aStatedLanguageIsNotOverwritten() throws {
        let file = try MatroskaFile(url: url)

        #expect(file.audioTrackDescriptions.map(\.language) == ["eng", "jpn"])
    }

    // MARK: - Container-agnostic listing

    /// The route a file description uses, so a `.mkv` lists its tracks as readily as an `.mp4`.
    /// AVFoundation cannot open this container at all, so its answer is empty and the demuxer's
    /// stands.
    @Test func listsMatroskaTracksThroughTheSharedEntryPoint() async throws {
        let tracks = await AudioTrackReader.readAnyContainer(from: url)

        #expect(tracks.count == 2)
        #expect(tracks.map(\.language) == ["eng", "jpn"])
    }

    /// A container AVFoundation *can* read is described by that path rather than falling through,
    /// so one file is never described two ways.
    @Test func prefersTheAVFoundationAnswerWhenThereIsOne() async throws {
        let tracks = await AudioTrackReader.readAnyContainer(
            from: TestBundleResources.shared.sample_dualaudio_mov
        )

        #expect(tracks.count == 2)
        #expect(tracks.allSatisfy { $0.codec == "aac" })
    }

    /// The video and subtitle tracks are not offered as audio, which a `compactMap` over every
    /// track would do if it keyed on anything but `kind`.
    @Test func describesOnlyTheAudioTracks() throws {
        let file = try MatroskaFile(url: url)

        #expect(file.tracks.count > file.audioTrackDescriptions.count)
        #expect(file.videoTrack?.audioTrackDescription == nil)
    }
}
