// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreAudioTypes
import Foundation

public extension MatroskaTrack {
    /// Whether ``audioChannelLayoutTag(firstPacket:)`` needs the track's first packet to answer.
    ///
    /// True for AC-3 and E-AC-3, whose configuration is stated only in each syncframe's header.
    var needsFirstPacketForChannelLayout: Bool {
        switch MatroskaAudioCodec(rawValue: codecID) {
        case .ac3, .eac3: true
        default: false
        }
    }

    /// The channel layout Core Audio's decoder outputs for this track, or `nil` when it is not known.
    ///
    /// **A Core Audio decoder told a discrete layout outputs silence**, so `nil` is not a layout to
    /// fall back on: it means the track cannot be decoded to more than two channels yet.
    ///
    /// - Parameter firstPacket: the track's first packet, which is where AC-3 and E-AC-3 state their
    ///   layout. Without it they answer from the channel count, which is unambiguous only at 1, 2
    ///   and 6. A header disagreeing with the track's channel count answers `nil`.
    func audioChannelLayoutTag(firstPacket: Data? = nil) -> AudioChannelLayoutTag? {
        guard case let .audio(parameters) = kind,
              let codec = MatroskaAudioCodec(rawValue: codecID)
        else {
            return nil
        }

        let channelCount = parameters.channelCount

        if codec == .ac3 || codec == .eac3, let firstPacket {
            guard let header = MatroskaAC3Header(frame: firstPacket),
                  header.channelCount == channelCount
            else {
                return nil
            }

            return header.channelLayoutTag
        }

        switch channelCount {
        case 1: return kAudioChannelLayoutTag_Mono
        case 2: return kAudioChannelLayoutTag_Stereo
        case 6: return codec.surround51LayoutTag
        default: return nil
        }
    }
}

extension MatroskaAudioCodec {
    /// The order Core Audio decodes this codec's 5.1 in.
    var surround51LayoutTag: AudioChannelLayoutTag? {
        switch self {
        case .ac3, .eac3: kAudioChannelLayoutTag_MPEG_5_1_C
        case .aac: kAudioChannelLayoutTag_MPEG_5_1_D
        case .flac: kAudioChannelLayoutTag_MPEG_5_1_A
        case .opus: kAudioChannelLayoutTag_Ogg_5_1
        case .mp3, .pcmIntegerLittleEndian, .pcmIntegerBigEndian, .pcmFloat: nil
        }
    }
}
