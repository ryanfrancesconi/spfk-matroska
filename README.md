# spfk-matroska

Matroska and WebM container reading for Swift, built on
[libwebm](https://github.com/webmproject/libwebm)'s `mkvparser` via
[spfk-mkvparser](https://github.com/ryanfrancesconi/spfk-mkvparser).

## Overview

Matroska is absent from `AVURLAsset.audiovisualTypes()`, so AVFoundation cannot open a `.mkv` or
`.webm` at all — no resolution, no frame rate, no playback. This package supplies the container
layer AVFoundation is missing.

**It demuxes and does not decode**, deliberately. Container parsing has no patent surface; video
and audio codecs are pool-licensed, and macOS already decodes H.264, HEVC, AV1, AAC, FLAC and Opus
natively through VideoToolbox and AudioToolbox. So this package hands back compressed frames plus
enough codec description to build a `CMFormatDescription`, and the caller decodes.

WebM is a Matroska profile, so one parser covers both containers.

## Usage

```swift
let file = try MatroskaFile(url: url)

file.docType           // .matroska or .webm
file.duration          // seconds, nil when the file states none
file.tracks            // every TrackEntry

if let video = file.videoTrack {
    video.codecID      // "V_MPEG4/ISO/AVC"
    video.codecPrivate // the avcC blob, verbatim
    video.frameRate
}

// Video-technical properties in spfk-video's shared shape, so a container AVFoundation
// cannot open still reports resolution and codec through the same type as everything else.
file.videoTrackProperties
```

Reading headers stops at the first cluster, so it costs the front of the file rather than a scan.

## Structure

| target | holds |
|---|---|
| `SPFKMatroskaC` | the ObjC++ bridge over `mkvparser`'s C++ API |
| `SPFKMatroska` | Swift value types (`MatroskaFile`, `MatroskaTrack`, `MatroskaError`) |

ObjC++ rather than Swift/C++ interop: `.interoperabilityMode(.Cxx)` propagates to every consumer,
which is not a cost callers should pay for a container reader.

The dependency on `spfk-video` runs one way — this package builds that package's
`VideoTrackProperties`, and `spfk-video` stays a pure-Swift leaf with no C++ in its graph.
