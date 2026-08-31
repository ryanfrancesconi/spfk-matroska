# spfk-matroska

Matroska and WebM container reading for Swift, built on
[libwebm](https://github.com/webmproject/libwebm)'s `mkvparser` via
[spfk-mkvparser](https://github.com/ryanfrancesconi/spfk-mkvparser).

## Overview

Matroska is absent from `AVURLAsset.audiovisualTypes()`, so AVFoundation cannot open a `.mkv` or
`.webm` at all — no resolution, no frame rate, no playback. This package supplies the container
layer AVFoundation is missing.

**It vendors no codec**, deliberately. Container parsing has no patent surface; video and audio
codecs are pool-licensed, and macOS already decodes H.264, HEVC, AV1, AAC, FLAC and Opus natively
through VideoToolbox and AudioToolbox. So this package hands back compressed frames plus enough
codec description to build a `CMFormatDescription`.

`MatroskaVideoDecoder` drives VideoToolbox rather than implementing anything — the boundary is that
no decoding *algorithm* is shipped here, not that the package refuses to call the system's.
Audio decoding lives in `spfk-audio-conversion`, since it belongs with the rest of the audio
conversion machinery.

WebM is a Matroska profile, so one parser covers both containers.

## Reading a file

`MatroskaFile` opens a URL and answers the container's doc type (Matroska or WebM), its duration
where it states one, and every track entry. Reading headers stops at the first cluster, so it costs
the front of the file rather than a scan.

`MatroskaTrack` carries a video track's codec ID, its `codecPrivate` blob verbatim, and its frame
rate, and builds `spfk-video`'s `VideoTrackProperties` — so a container AVFoundation cannot open
still reports resolution and codec through the same type as everything else. It builds
`AudioTrackDescription` the same way, so the audio-track picker is written once for both backends.

## Frames

`MatroskaFrameReader` walks a track's blocks and seeks by timestamp, handing back a `MatroskaFrame`
with its data, timestamp and keyframe flag. `MatroskaSampleBufferReader` wraps those as
`CMSampleBuffer`s — a `MatroskaSampleBatch` at a time — for an `AVSampleBufferDisplayLayer` or an
`AVSampleBufferAudioRenderer`.

`MatroskaVideoDecoder` drives VideoToolbox over that, producing `MatroskaVideoFrame`s.
`SupplementalVideoDecoders` covers the formats macOS will decode only once their decoder is
requested.

**Cues typically index only the video track.** Clusters interleave every track, so a seek on an
audio track resolves through the video track's cue point and then walks — which is what makes
seeking an audio-only read of a `.mkv` fast rather than a decode from zero.

## Audio stream description

`MatroskaTrack.makeAudioStreamBasicDescription()` is the single description every consumer builds
from — the format description for the sample-buffer path, the decoder's input format, and the
`isDecodable` answer all derive from it, so they cannot disagree.

`MatroskaAudioCodec` names the codecs the reader understands, `MatroskaPCMSampleFormat` the raw
sample layouts, and `MatroskaFLACStreamInfo` the STREAMINFO block a FLAC track carries.

It is exacting in a way worth knowing: **a wrong `AudioStreamBasicDescription` does not fail.**
`AVAudioConverter` builds happily from one, consumes every packet, emits zero frames and reports
success at each step. `mFramesPerPacket` in particular is a property of the *file* for FLAC (its
block size, in STREAMINFO) rather than a per-codec constant, which is why this is derived from the
track instead of from a table.

## Structure

| target | holds |
|---|---|
| `SPFKMatroskaC` | the ObjC++ bridge over `mkvparser`'s C++ API |
| `SPFKMatroska` | Swift value types (`MatroskaFile`, `MatroskaTrack`, `MatroskaError`) |

ObjC++ rather than Swift/C++ interop: `.interoperabilityMode(.Cxx)` propagates to every consumer,
which is not a cost callers should pay for a container reader.

The dependency on `spfk-video` runs one way — this package builds that package's
`VideoTrackProperties`, and `spfk-video` stays a pure-Swift leaf with no C++ in its graph.

## Requirements

- **Platforms:** macOS 13+, iOS 16+
- **Swift:** 6.2+

## Dependencies

| Package | Purpose |
|---------|---------|
| [spfk-mkvparser](https://github.com/ryanfrancesconi/spfk-mkvparser) | libwebm's `mkvparser`, packaged for SPM |
| [spfk-base](https://github.com/ryanfrancesconi/spfk-base) | Core utilities and logging |
| [spfk-video](https://github.com/ryanfrancesconi/spfk-video) | `VideoTrackProperties`, `VideoFrameExtractor` |
| [spfk-testing](https://github.com/ryanfrancesconi/spfk-testing) | Matroska fixtures (test target only) |

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
