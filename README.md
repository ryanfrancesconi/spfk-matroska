# spfk-matroska

The Matroska and WebM container layer AVFoundation lacks. Matroska is not among the types
AVFoundation opens, so without this an app cannot read a `.mkv` or `.webm` file's tracks, resolution
or frames at all. An app embeds it to treat those files like any other media: it reads the
container's tracks, hands back compressed frames as sample buffers, and decodes video through
VideoToolbox.

Most callers never name a Matroska type. The any-container entry points, such as
`VideoTrackReader.readAnyContainer(from:)` and `VideoFrameExtractor.framesForAnyContainer`, try
AVFoundation first and fall back to the demuxer, filling the same
[spfk-video](https://github.com/ryanfrancesconi/spfk-video) types either way. WebM is a Matroska
profile, so one parser covers both.

**It vendors no codec.** Container parsing is built on libwebm's parser, repackaged in
[spfk-mkvparser](https://github.com/ryanfrancesconi/spfk-mkvparser); decoding uses what macOS
already ships. Audio decoding belongs to spfk-audio-conversion, and tag reading and writing for
Matroska to spfk-metadata.

## Audio stream descriptions

A wrong `AudioStreamBasicDescription` does not fail: `AVAudioConverter` accepts it, consumes every
packet and emits silence. So every consumer builds from the one description a track derives,
`MatroskaTrack.makeAudioStreamBasicDescription()`, read from the track rather than a per-codec
table. A FLAC track's packet length, for one, is a property of the file.

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
