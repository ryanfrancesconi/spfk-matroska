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

    /// Old or malformed files state no `TrackUID`, or the same one twice; every track must still be
    /// selectable on its own.
    @Test(arguments: [nil, UInt64(7)])
    func tracksWithoutDistinctUIDsGetDistinctIdentifiers(uid: UInt64?) throws {
        let file = MatroskaTestFile(
            tracks: [.pcm(number: 1, uid: uid), .pcm(number: 2, uid: uid)],
            clusters: [.init(timecode: 0, blocks: [
                .init(track: 1, frames: [Data(repeating: 1, count: 4)]),
                .init(track: 2, frames: [Data(repeating: 2, count: 4)]),
            ])]
        )

        let fileURL = try file.writeTemporary(pathExtension: "mka")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let matroska = try MatroskaFile(url: fileURL)
        let ids = matroska.audioTrackDescriptions.map(\.id)

        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        #expect(ids.compactMap { matroska.audioTrack(id: $0)?.number } == [1, 2])
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

    /// Writes a copy of the fixture with the one occurrence of `element` replaced byte-for-byte.
    private func patchedCopy(replacing element: Data, with replacement: Data) throws -> URL {
        var data = try Data(contentsOf: url)
        var occurrences = 0
        var start = data.startIndex

        while let range = data.range(of: element, in: start ..< data.endIndex) {
            occurrences += 1
            start = range.upperBound
        }

        #expect(occurrences == 1)
        let range = try #require(data.range(of: element))
        data.replaceSubrange(range, with: replacement)

        let patched = FileManager.default.temporaryDirectory
            .appendingPathComponent("spfk-patched-\(UUID().uuidString).mkv")
        try data.write(to: patched)
        return patched
    }

    /// A name with a byte that isn't valid UTF-8 reads with a replacement character, as ffprobe
    /// shows it, rather than not at all.
    @Test func readsANameWithAnInvalidByteLossily() throws {
        // `Name` (0x536E), a 1-byte size of 7, then "English".
        let element = Data([0x53, 0x6E, 0x87]) + Data("English".utf8)
        let replacement = Data([0x53, 0x6E, 0x87]) + Data("Engl".utf8) + Data([0xE9]) + Data("sh".utf8)
        let patched = try patchedCopy(replacing: element, with: replacement)
        defer { try? FileManager.default.removeItem(at: patched) }

        let expected = String(decoding: Data("Engl".utf8) + [0xE9] + Data("sh".utf8), as: UTF8.self)
        let file = try MatroskaFile(url: patched)

        #expect(file.audioTrack?.name == expected)
    }

    /// A language that can't be decoded is undetermined, not the spec default for an absent one.
    @Test func readsAnUndecodableLanguageAsUndetermined() throws {
        // `Language` (0x22B59C), a 1-byte size of 3, then "jpn".
        let element = Data([0x22, 0xB5, 0x9C, 0x83]) + Data("jpn".utf8)
        let replacement = Data([0x22, 0xB5, 0x9C, 0x83]) + Data("j".utf8) + Data([0xFF]) + Data("n".utf8)
        let patched = try patchedCopy(replacing: element, with: replacement)
        defer { try? FileManager.default.removeItem(at: patched) }

        let file = try MatroskaFile(url: patched)
        let japanese = try #require(file.tracks.first { $0.name == "Japanese" })

        #expect(japanese.language == "und")
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

    /// **An `.mka` has no video track, and that is the whole test.** `org.matroska.mka` conforms to
    /// `.audio` rather than `.movie`, so a listing reached through a video test never runs — while
    /// the demuxer itself never cared.
    @Test func listsTheAudioTracksOfAVideolessMatroskaFile() async throws {
        let mka = TestBundleResources.shared.dualaudio_mka

        let file = try MatroskaFile(url: mka)
        #expect(file.videoTrack == nil)

        let tracks = await AudioTrackReader.readAnyContainer(from: mka)

        #expect(tracks.count == 2)
        #expect(tracks.map(\.language) == ["eng", "jpn"])
        #expect(tracks.map(\.displayName) == ["English", "Japanese"])
    }

    /// The video and subtitle tracks are not offered as audio, which a `compactMap` over every
    /// track would do if it keyed on anything but `kind`.
    @Test func describesOnlyTheAudioTracks() throws {
        let file = try MatroskaFile(url: url)

        #expect(file.tracks.count > file.audioTrackDescriptions.count)
        #expect(file.videoTrack?.audioTrackDescription == nil)
    }
}
