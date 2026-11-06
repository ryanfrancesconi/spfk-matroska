# spfk-matroska

Matroska and WebM support for macOS, which AVFoundation does not open. It reads a file's tracks,
returns compressed frames as sample buffers, and decodes video through VideoToolbox. Parsing is
built on [spfk-mkvparser](https://github.com/ryanfrancesconi/spfk-mkvparser); no codec is vendored.

## Features

- `VideoTrackReader.readAnyContainer(from:)`, `AudioTrackReader.readAnyContainer(from:)` and
  `VideoFrameExtractor.framesForAnyContainer` try AVFoundation first and fall back to the Matroska
  demuxer, returning the same [spfk-video](https://github.com/ryanfrancesconi/spfk-video) types
- `MatroskaTrack.makeAudioStreamBasicDescription()` derives an audio track's stream description
  from the track itself

## About

Spongefork is the personal software projects of musician and developer [Ryan Francesconi](https://spongefork.com). Dedicated to creative sound manipulation, his first application, Spongefork, was released in 1999 for macOS 8. From 2026, Spongefork returns as his software container for more musical experimentation. In addition to [software releases](https://spongefork.com/shadowtag/), open source components can be found on his [GitHub page](https://github.com/ryanfrancesconi).
