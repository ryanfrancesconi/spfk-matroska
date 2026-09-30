// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVDescription+Internal.h"

#include <string>

/// Replaces each maximal ill-formed subsequence with U+FFFD, the rule Swift's
/// `String(decoding:as:)` follows.
static NSString *MKVDecodeUTF8Lossily(const char *value) {
    const auto *bytes = reinterpret_cast<const unsigned char *>(value);
    const size_t length = strlen(value);
    std::string output;
    output.reserve(length);

    size_t i = 0;
    while (i < length) {
        const unsigned char lead = bytes[i];
        size_t needed = 0;
        unsigned char low = 0x80, high = 0xBF;

        if (lead < 0x80) {
            output.push_back(static_cast<char>(lead));
            i++;
            continue;
        } else if (lead >= 0xC2 && lead <= 0xDF) {
            needed = 1;
        } else if (lead >= 0xE0 && lead <= 0xEF) {
            needed = 2;
            if (lead == 0xE0) { low = 0xA0; }
            if (lead == 0xED) { high = 0x9F; }
        } else if (lead >= 0xF0 && lead <= 0xF4) {
            needed = 3;
            if (lead == 0xF0) { low = 0x90; }
            if (lead == 0xF4) { high = 0x8F; }
        } else {
            output.append("\xEF\xBF\xBD");
            i++;
            continue;
        }

        size_t consumed = 1;
        bool valid = true;
        while (consumed <= needed) {
            if (i + consumed >= length) {
                valid = false;
                break;
            }
            const unsigned char next = bytes[i + consumed];
            // Only the second byte has a narrowed range.
            const unsigned char lo = consumed == 1 ? low : 0x80;
            const unsigned char hi = consumed == 1 ? high : 0xBF;
            if (next < lo || next > hi) {
                valid = false;
                break;
            }
            consumed++;
        }

        if (valid) {
            output.append(reinterpret_cast<const char *>(bytes + i), consumed);
        } else {
            output.append("\xEF\xBF\xBD");
        }
        i += consumed;
    }

    return [[NSString alloc] initWithBytes:output.data() length:output.size() encoding:NSUTF8StringEncoding];
}

NSString *_Nullable MKVStringOrNil(const char *_Nullable value) {
    if (value == nullptr) {
        return nil;
    }
    return [NSString stringWithUTF8String:value] ?: MKVDecodeUTF8Lossily(value);
}

@implementation MKVTrackDescription

- (instancetype)initWithTrack:(const mkvparser::Track *)track {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _number = track->GetNumber();
    _uid = track->GetUid();
    _type = (MKVTrackType)track->GetType();
    _codecID = MKVStringOrNil(track->GetCodecId());
    _codecName = MKVStringOrNil(track->GetCodecNameAsUTF8());
    _name = MKVStringOrNil(track->GetNameAsUTF8());
    // Absent stays nil so the spec default applies; present but undecodable is undetermined.
    const char *language = track->GetLanguage();
    if (language != nullptr) {
        _language = [NSString stringWithUTF8String:language] ?: @"und";
    }
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
