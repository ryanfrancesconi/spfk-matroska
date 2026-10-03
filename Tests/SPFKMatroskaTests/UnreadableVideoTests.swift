// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation
import SPFKBase
import SPFKTesting
import SPFKVideo
import Testing

@testable import SPFKMatroska

/// `VideoTrackReader.isUnreadableVideo` over what `readAnyContainer` actually reports.
@Suite(.tags(.file), .serialized)
final class UnreadableVideoTests: BinTestCase {
    private func isUnreadable(_ url: URL) async -> Bool {
        let result = await VideoTrackReader.readAnyContainer(from: url)
        let isDecodable = result.isPlayable ? false : (try? MatroskaFile(url: url))?.videoTrack?.isDecodable == true

        return VideoTrackReader.isUnreadableVideo(
            videoTrack: result.videoTrack, isAVPlayable: result.isPlayable, isDecodable: isDecodable
        )
    }

    /// TypeScript shares `.ts` with MPEG transport streams.
    @Test func aTextFileUnderAVideoExtensionIsUnreadable() async throws {
        deleteBinOnExit = true

        let url = bin.appendingPathComponent("ws.d.ts")
        try "import { URISchemeHandler } from \"../uri\";\n".write(to: url, atomically: true, encoding: .utf8)

        #expect(await isUnreadable(url))
    }

    /// An audio-only transport stream has no video track and plays.
    @Test func anAudioOnlyTransportStreamIsReadable() async {
        #expect(await isUnreadable(TestBundleResources.shared.sine_ts) == false)
    }

    @Test(arguments: [TestBundleResources.shared.sample_mov, TestBundleResources.shared.sample_mkv])
    func aVideoIsReadable(url: URL) async {
        #expect(await isUnreadable(url) == false)
    }
}
