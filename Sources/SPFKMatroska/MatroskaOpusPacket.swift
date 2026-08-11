// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import Foundation

/// The length of an Opus packet, read from the packet itself.
///
/// Opus states its frame size per *packet* rather than per stream — one file may mix 2.5 ms through
/// 60 ms — so there is no track-level figure to place packets on a grid with. The first byte (the
/// TOC) gives the configuration and how many frames follow it.
///
/// Layout, from RFC 6716 §3.1: the top five bits are the configuration, the next is the stereo
/// flag, and the low two say how many frames the packet holds.
enum MatroskaOpusPacket {
    /// Frames this packet decodes to at 48 kHz, or `nil` if it is malformed.
    static func frameCount(_ data: Data) -> Int? {
        guard let toc = data.first else { return nil }

        let configuration = Int(toc >> 3)
        let frameSize: Int

        switch configuration {
        case 0 ... 11:
            // SILK: 10, 20, 40, 60 ms.
            frameSize = [480, 960, 1920, 2880][configuration & 3]

        case 12 ... 15:
            // Hybrid: 10 or 20 ms.
            frameSize = [480, 960][configuration & 1]

        default:
            // CELT: 2.5, 5, 10, 20 ms.
            frameSize = [120, 240, 480, 960][configuration & 3]
        }

        let frames: Int

        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            // An arbitrary count, stated in the low six bits of the next byte. Zero is malformed.
            guard data.count > 1 else { return nil }
            frames = Int(data[data.index(data.startIndex, offsetBy: 1)] & 0x3F)
        }

        guard frames > 0 else { return nil }

        return frameSize * frames
    }
}
