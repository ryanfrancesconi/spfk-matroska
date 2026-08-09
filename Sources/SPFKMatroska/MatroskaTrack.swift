// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi/spfk-matroska

import CoreGraphics
import Foundation
import SPFKMatroskaC

/// One `TrackEntry` from a Matroska file's `Tracks` element.
public struct MatroskaTrack: Hashable, Sendable, Identifiable {
    /// What the track carries, and the parameters that only make sense for that kind.
    public enum Kind: Hashable, Sendable {
        case video(VideoParameters)
        case audio(AudioParameters)
        case subtitle

        /// Matroska's own metadata track type, unrelated to file tags.
        case metadata

        /// A `TrackType` this package does not model, carried through rather than discarded so a
        /// caller can see what it skipped.
        case other(Int)
    }

    /// What `DisplayWidth`/`DisplayHeight` are measured in.
    public enum DisplayUnit: Hashable, Sendable {
        case pixels
        case centimeters
        case inches
        case displayAspectRatio

        /// A `DisplayUnit` this package does not model, carried through rather than silently
        /// treated as pixels.
        case other(Int)

        init(_ rawValue: Int) {
            self = switch rawValue {
            case 0: .pixels
            case 1: .centimeters
            case 2: .inches
            case 3: .displayAspectRatio
            default: .other(rawValue)
            }
        }
    }

    /// Video parameters, as the file states them. Nothing here is derived or corrected.
    public struct VideoParameters: Hashable, Sendable {
        /// The encoded frame size — what a decoder produces.
        public let pixelWidth: Int
        public let pixelHeight: Int

        /// The intended presentation size, which encodes non-square pixels and so need not match
        /// the pixel size. 0 when the file omits it, in which case the pixel size is the display
        /// size. Only pixels when ``displayUnit`` says so.
        public let displayWidth: Int
        public let displayHeight: Int

        /// What ``displayWidth``/``displayHeight`` are measured in. Anything but ``DisplayUnit/pixels``
        /// makes them a physical size or a ratio, not a resolution.
        public let displayUnit: DisplayUnit

        /// The `FrameRate` element. Deprecated in Matroska and omitted by most muxers, so this is
        /// usually `nil` — ``MatroskaTrack/frameRate`` derives the real answer.
        public let declaredFrameRate: Double?
    }

    /// Audio parameters, as the file states them.
    public struct AudioParameters: Hashable, Sendable {
        public let sampleRate: Double
        public let channelCount: Int

        /// `BitDepth`, `nil` for compressed codecs that do not state one.
        public let bitDepth: Int?
    }

    /// The `TrackNumber` blocks reference. One-based and not necessarily contiguous, so it is an
    /// identifier rather than an index into ``MatroskaFile/tracks``.
    public let number: Int

    /// `TrackUID` — identity that survives a remux, where ``number`` is positional and does not.
    /// What a selection persisted across sessions is keyed on; ``number`` is what a reader is
    /// opened with.
    public let uid: UInt64

    public var id: Int { number }

    public let kind: Kind

    /// The Matroska `CodecID`, e.g. `V_MPEG4/ISO/AVC` or `A_AAC`.
    public let codecID: String

    public let codecName: String?
    public let name: String?

    /// `Language`, ISO-639-2.
    ///
    /// **`eng` when the file states none**, which is the element's declared default in the Matroska
    /// spec — so muxers omit it for English and write it only for everything else. libwebm applies
    /// no default (its `Track::Info` initializes `language(NULL)` and fills it only from a present
    /// element), which made an English track read as having no language at all while every other
    /// track had one. ffmpeg applies the same default, which is why `ffprobe` shows `eng` for a
    /// track this reader called `nil`.
    public let language: String?

    /// `CodecPrivate` — the codec's out-of-band setup data, needed to build a format description.
    /// For H.264 this is the `avcC` blob verbatim.
    public let codecPrivate: Data?

    /// `DefaultDuration` in nanoseconds — how long one frame lasts. `nil` when unstated.
    public let defaultFrameDurationNanoseconds: UInt64?

    /// Frames per second, preferring the declared `FrameRate` and falling back to the reciprocal of
    /// ``defaultFrameDurationNanoseconds``. `nil` when the file states neither, which is normal for
    /// variable-frame-rate captures — the real rate is then only knowable by walking clusters.
    public var frameRate: Double? {
        if case let .video(parameters) = kind, let declared = parameters.declaredFrameRate, declared > 0 {
            return declared
        }

        guard let nanoseconds = defaultFrameDurationNanoseconds, nanoseconds > 0 else {
            return nil
        }

        return 1_000_000_000 / Double(nanoseconds)
    }

    /// The presentation size in pixels, resolving Matroska's rule that an omitted `DisplayWidth`/
    /// `DisplayHeight` means the pixel dimensions. `nil` for a non-video track.
    ///
    /// Falls back to the pixel size when `DisplayUnit` is anything but pixels — centimeters,
    /// inches and a bare aspect ratio are all real values there, and none of them is a resolution.
    public var displaySize: CGSize? {
        guard case let .video(parameters) = kind else {
            return nil
        }

        guard parameters.displayUnit == .pixels,
              parameters.displayWidth > 0,
              parameters.displayHeight > 0
        else {
            return CGSize(width: parameters.pixelWidth, height: parameters.pixelHeight)
        }

        return CGSize(width: parameters.displayWidth, height: parameters.displayHeight)
    }
}

// MARK: - Bridging

extension MatroskaTrack {
    /// The Matroska spec's declared default for `TrackEntry\Language`.
    static let defaultLanguage = "eng"

    init(_ description: MKVTrackDescription) {
        number = Int(description.number)
        uid = description.uid
        codecID = description.codecID ?? ""
        codecName = description.codecName
        name = description.name
        language = description.language ?? Self.defaultLanguage
        codecPrivate = description.codecPrivate
        defaultFrameDurationNanoseconds = description.defaultDuration > 0 ? description.defaultDuration : nil

        kind = switch description.type {
        case .video:
            .video(
                VideoParameters(
                    pixelWidth: Int(description.pixelWidth),
                    pixelHeight: Int(description.pixelHeight),
                    displayWidth: Int(description.displayWidth),
                    displayHeight: Int(description.displayHeight),
                    displayUnit: DisplayUnit(Int(description.displayUnit)),
                    declaredFrameRate: description.frameRate > 0 ? description.frameRate : nil
                )
            )

        case .audio:
            .audio(
                AudioParameters(
                    sampleRate: description.sampleRate,
                    channelCount: Int(description.channelCount),
                    bitDepth: description.bitDepth > 0 ? Int(description.bitDepth) : nil
                )
            )

        case .subtitle:
            .subtitle

        case .metadata:
            .metadata

        default:
            .other(description.type.rawValue)
        }
    }
}
