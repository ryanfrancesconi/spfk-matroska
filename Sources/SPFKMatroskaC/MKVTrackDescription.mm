// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVDescription+Internal.h"

NSString *_Nullable MKVStringOrNil(const char *_Nullable value) {
    if (value == nullptr) {
        return nil;
    }
    return [NSString stringWithUTF8String:value];
}

@implementation MKVTrackDescription

- (instancetype)initWithTrack:(const mkvparser::Track *)track {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _number = track->GetNumber();
    _type = (MKVTrackType)track->GetType();
    _codecID = MKVStringOrNil(track->GetCodecId());
    _codecName = MKVStringOrNil(track->GetCodecNameAsUTF8());
    _name = MKVStringOrNil(track->GetNameAsUTF8());
    _language = MKVStringOrNil(track->GetLanguage());
    _defaultDuration = track->GetDefaultDuration();

    size_t codecPrivateSize = 0;
    const unsigned char *codecPrivate = track->GetCodecPrivate(codecPrivateSize);

    // The parser owns the buffer for the lifetime of its Segment, which ends when the demuxer
    // returns -- so this copies rather than wrapping.
    if (codecPrivate != nullptr && codecPrivateSize > 0) {
        _codecPrivate = [NSData dataWithBytes:codecPrivate length:codecPrivateSize];
    }

    switch (track->GetType()) {
    case mkvparser::Track::kVideo: {
        const auto *video = static_cast<const mkvparser::VideoTrack *>(track);
        _pixelWidth = video->GetWidth();
        _pixelHeight = video->GetHeight();
        _displayWidth = video->GetDisplayWidth();
        _displayHeight = video->GetDisplayHeight();
        _displayUnit = video->GetDisplayUnit();
        _frameRate = video->GetFrameRate();
        break;
    }
    case mkvparser::Track::kAudio: {
        const auto *audio = static_cast<const mkvparser::AudioTrack *>(track);
        _sampleRate = audio->GetSamplingRate();
        _channelCount = audio->GetChannels();
        _bitDepth = audio->GetBitDepth();
        break;
    }
    default:
        break;
    }

    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<MKVTrackDescription %lld type:%ld codec:%@>", _number, (long)_type, _codecID];
}

@end
